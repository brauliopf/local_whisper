import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import {
  redactControl,
  redactText,
  sanitizeURL,
  type PageSnapshot,
} from "./redaction.js";

const PROTOCOL_VERSION = 1;

type Command = {
  id: string;
  version: number;
  session_id: string;
  deadline_ms?: number;
  type: "start" | "snapshot" | "pause" | "resume" | "stop";
};

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
let pauseGeneration = 0;
let sessionID: string | undefined;

function reply(command: Command, ok: boolean, state: SidecarState, error?: string): void {
  process.stdout.write(`${JSON.stringify({
    id: command.id,
    version: PROTOCOL_VERSION,
    session_id: command.session_id,
    ok,
    ...state,
    ...(error ? { error } : {}),
  })}\n`);
}

function errorCategory(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("timeout")) return "operation_timeout";
  if (message.includes("launch") || message.includes("executable")) return "browser_unavailable";
  return "browser_operation_failed";
}

async function snapshot(): Promise<PageSnapshot | undefined> {
  if (!page) throw new Error("Browser tab is not running");
  const generation = pauseGeneration;

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

  if (paused || generation !== pauseGeneration) return undefined;

  const redacted = {
    url: sanitizeURL(data.url),
    title: redactText(data.title),
    visibleText: redactText(data.visibleText),
    controls: data.controls.map(redactControl),
  };
  return {
    ...redacted,
    stateHash: createHash("sha256").update(JSON.stringify(redacted)).digest("hex"),
  };
}

async function start(): Promise<PageSnapshot | undefined> {
  if (!browser) {
    browser = await chromium.launch({ headless: false });
    context = await browser.newContext();
    page = await context.newPage();
    context.on("page", (extraPage) => {
      if (extraPage !== page) {
        void extraPage.close();
        process.stderr.write("Rejected unexpected additional browser tab\n");
      }
    });
    browser.on("disconnected", () => {
      browser = undefined;
      context = undefined;
      page = undefined;
      paused = false;
      pauseGeneration += 1;
    });
  }
  if (!page) throw new Error("Browser tab is unavailable");
  return snapshot();
}

async function handle(command: Command): Promise<void> {
  if (command.version !== PROTOCOL_VERSION || !command.session_id) {
    reply(command, false, { status: "idle" }, "protocol_invalid");
    return;
  }
  if (sessionID && command.session_id !== sessionID) {
    reply(command, false, { status: browser ? "running" : "idle" }, "session_mismatch");
    return;
  }
  if (command.type === "start") sessionID = command.session_id;
  if (command.deadline_ms !== undefined && Date.now() > command.deadline_ms) {
    reply(command, false, { status: browser ? (paused ? "paused" : "running") : "idle" }, "request_expired");
    return;
  }

  try {
    switch (command.type) {
      case "start": {
        const pageSnapshot = await start();
        reply(command, true, { status: "running", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "snapshot": {
        if (paused) {
          reply(command, true, { status: "paused" });
          return;
        }
        const pageSnapshot = await snapshot();
        reply(command, true, { status: pageSnapshot ? "running" : "paused", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "pause":
        paused = true;
        pauseGeneration += 1;
        reply(command, true, { status: "paused" });
        return;
      case "resume": {
        paused = false;
        pauseGeneration += 1;
        const pageSnapshot = await snapshot();
        reply(command, true, { status: "running", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "stop":
        await browser?.close();
        browser = undefined;
        context = undefined;
        page = undefined;
        paused = false;
        pauseGeneration += 1;
        sessionID = undefined;
        reply(command, true, { status: "stopped" });
        setImmediate(() => process.exit(0));
        return;
    }
  } catch (error) {
    reply(command, false, { status: browser ? (paused ? "paused" : "running") : "idle" }, errorCategory(error));
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let commandQueue = Promise.resolve();
input.on("line", (line) => {
  try {
    const command = JSON.parse(line) as Command;
    commandQueue = commandQueue.then(() => handle(command)).catch(() => undefined);
  } catch {
    process.stderr.write("Invalid sidecar command\n");
  }
});

process.on("SIGTERM", () => void browser?.close().finally(() => process.exit(0)));
process.on("SIGINT", () => void browser?.close().finally(() => process.exit(0)));
