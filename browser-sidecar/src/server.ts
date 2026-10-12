import { createInterface } from "node:readline";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import {
  redactControl,
  redactText,
  type PageSnapshot,
} from "./redaction.js";

type Command =
  | { id: string; type: "start" }
  | { id: string; type: "snapshot" }
  | { id: string; type: "pause" }
  | { id: string; type: "resume" }
  | { id: string; type: "stop" };

interface ControlData {
  tag: string;
  type: string | null;
  name: string | null;
  autocomplete: string | null;
  label: string | null;
  value: string | null;
}

interface SidecarState {
  status: "idle" | "running" | "paused" | "stopped";
  snapshot?: PageSnapshot;
}

let browser: Browser | undefined;
let context: BrowserContext | undefined;
let page: Page | undefined;
let paused = false;

function reply(id: string, ok: boolean, state: SidecarState, error?: string): void {
  process.stdout.write(`${JSON.stringify({ id, ok, ...state, ...(error ? { error } : {}) })}\n`);
}

async function snapshot(): Promise<PageSnapshot> {
  if (!page) throw new Error("Browser tab is not running");

  const data = await page.evaluate(() => {
    const labelFor = (element: Element): string | null => {
      if (!(element instanceof HTMLElement)) return null;
      const id = element.getAttribute("id");
      if (id) {
        const label = document.querySelector(`label[for="${CSS.escape(id)}"]`);
        if (label?.textContent) return label.textContent.trim();
      }
      return element.getAttribute("aria-label") ?? element.getAttribute("placeholder");
    };

    const controls: ControlData[] = Array.from(
      document.querySelectorAll("input, textarea, select, button"),
    ).map((element) => ({
      tag: element.tagName.toLowerCase(),
      type: element.getAttribute("type"),
      name: element.getAttribute("name"),
      autocomplete: element.getAttribute("autocomplete"),
      label: labelFor(element),
      value: element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
        ? element.value
        : element.textContent?.trim() ?? "",
    }));

    return {
      url: location.href,
      title: document.title,
      visibleText: document.body?.innerText ?? "",
      controls,
    };
  });

  return {
    url: data.url,
    title: redactText(data.title),
    visibleText: redactText(data.visibleText),
    controls: data.controls.map(redactControl),
  };
}

async function start(): Promise<PageSnapshot> {
  if (!browser) {
    browser = await chromium.launch({ headless: false });
    context = await browser.newContext();
    page = await context.newPage();
    context.on("page", (extraPage) => {
      if (extraPage !== page) {
        void extraPage.close();
        console.error("Rejected unexpected additional browser tab");
      }
    });
    browser.on("disconnected", () => {
      browser = undefined;
      context = undefined;
      page = undefined;
      paused = false;
    });
  }
  if (!page) throw new Error("Browser tab is unavailable");
  return snapshot();
}

async function handle(command: Command): Promise<void> {
  try {
    switch (command.type) {
      case "start":
        reply(command.id, true, { status: "running", snapshot: await start() });
        return;
      case "snapshot":
        if (paused) {
          reply(command.id, true, { status: "paused" });
          return;
        }
        reply(command.id, true, { status: "running", snapshot: await snapshot() });
        return;
      case "pause":
        paused = true;
        reply(command.id, true, { status: "paused" });
        return;
      case "resume":
        paused = false;
        reply(command.id, true, { status: "running", snapshot: await snapshot() });
        return;
      case "stop":
        await browser?.close();
        browser = undefined;
        context = undefined;
        page = undefined;
        paused = false;
        reply(command.id, true, { status: "stopped" });
        return;
    }
  } catch (error) {
    reply(command.id, false, { status: browser ? (paused ? "paused" : "running") : "idle" }, error instanceof Error ? error.message : "Sidecar request failed");
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  try {
    const command = JSON.parse(line) as Command;
    void handle(command);
  } catch {
    process.stderr.write("Invalid sidecar command\n");
  }
});

process.on("SIGTERM", () => void browser?.close().finally(() => process.exit(0)));
process.on("SIGINT", () => void browser?.close().finally(() => process.exit(0)));
