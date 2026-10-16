import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import {
  redactControl,
  redactText,
  sanitizeURL,
  type PageSnapshot,
} from "./redaction.js";
import { awaitAndClose } from "./shutdown.js";
import { isSafeBrowserURL } from "./validator.js";
import { executeBrowserPlan } from "./execution.js";

const PROTOCOL_VERSION = 1;

type Command = {
  id: string;
  version: number;
  session_id: string;
  deadline_ms?: number;
  type: "start" | "snapshot" | "pause" | "resume" | "stop" | "execute";
  code?: string;
  code_hash?: string;
  state_hash?: string;
  policy_version?: string;
  expires_at?: string;
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
let auxiliaryPage: Page | undefined;
let paused = false;
let pauseGeneration = 0;
let sessionID: string | undefined;
let lifecycleGeneration = 0;
let shuttingDown = false;
let launchInFlight: Promise<Browser> | undefined;
let teardownInFlight: Promise<void> | undefined;

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

function isCommand(value: unknown): value is Command {
  if (!value || typeof value !== "object") return false;
  const command = value as Record<string, unknown>;
  return typeof command.id === "string"
    && typeof command.version === "number"
    && typeof command.session_id === "string"
    && (command.deadline_ms === undefined || (typeof command.deadline_ms === "number" && Number.isFinite(command.deadline_ms)))
    && ["start", "snapshot", "pause", "resume", "stop", "execute"].includes(command.type as string)
    && (command.type !== "execute" || (typeof command.code === "string" && typeof command.code_hash === "string" && typeof command.state_hash === "string" && typeof command.policy_version === "string" && typeof command.expires_at === "string"));
}

function invalidCommand(value: unknown): Command {
  const command = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return {
    id: typeof command.id === "string" ? command.id : "",
    version: typeof command.version === "number" ? command.version : 0,
    session_id: typeof command.session_id === "string" ? command.session_id : "",
    type: "stop",
  };
}

function errorCategory(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("timeout")) return "operation_timeout";
  if (message.includes("code hash")) return "code_hash_mismatch";
  if (message.includes("stale browser state")) return "stale_browser_state";
  if (message.includes("expired browser plan")) return "expired_browser_plan";
  if (message.includes("policy violation")) return "policy_violation";
  if (message.includes("launch") || message.includes("executable")) return "browser_unavailable";
  return "browser_operation_failed";
}

async function withDeadline<T>(deadline: number | undefined, operation: () => Promise<T>, onTimeout?: () => void): Promise<T> {
  if (deadline === undefined) return operation();
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("operation timeout");
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation(),
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error("operation timeout")), remaining);
      }),
    ]);
  } catch (error) {
    if (error instanceof Error && error.message === "operation timeout") onTimeout?.();
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
  }
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
      controls,
    };
  });

  if (paused || generation !== pauseGeneration) return undefined;

  const redacted = {
    url: sanitizeURL(data.url),
    title: redactText(data.title),
    controls: data.controls.map(redactControl),
  };
  return {
    ...redacted,
    stateHash: createHash("sha256").update(JSON.stringify(redacted)).digest("hex"),
  };
}

async function start(): Promise<PageSnapshot | undefined> {
  shuttingDown = false;
  if (!browser) {
    const generation = lifecycleGeneration;
    const launchPromise = chromium.launch({ headless: false });
    launchInFlight = launchPromise;
    let launchedBrowser: Browser;
    try {
      launchedBrowser = await launchPromise;
    } finally {
      if (launchInFlight === launchPromise) launchInFlight = undefined;
    }
    // Publish ownership immediately so EOF/signal shutdown can close a browser
    // while context/page initialization is still in flight.
    browser = launchedBrowser;
    try {
      if (generation !== lifecycleGeneration || shuttingDown) {
        throw new Error("operation timeout");
      }
      const launchedContext = await launchedBrowser.newContext();
      await launchedContext.route("**/*", async (route) => {
        const rawURL = route.request().url();
        if (rawURL === "about:blank" || isSafeBrowserURL(rawURL)) {
          await route.continue();
          return;
        }
        await route.abort("blockedbyclient");
      });
      let acceptedPage: Page | undefined;
      launchedContext.on("page", (newPage) => {
        if (!acceptedPage) {
          acceptedPage = newPage;
          return;
        }
        if (!auxiliaryPage) {
          auxiliaryPage = newPage;
          newPage.once("close", () => {
            if (auxiliaryPage === newPage) auxiliaryPage = undefined;
          });
          process.stderr.write("Accepted auxiliary user window\n");
          return;
        }
        void newPage.close().catch(() => undefined);
        process.stderr.write("Rejected unexpected additional browser tab\n");
      });
      const launchedPage = await launchedContext.newPage();
      acceptedPage = launchedPage;
      if (generation !== lifecycleGeneration || shuttingDown) {
        throw new Error("operation timeout");
      }
      context = launchedContext;
      page = launchedPage;
      launchedPage.once("close", () => handlePrimaryPageClose(launchedPage));
      if (launchedPage.isClosed()) handlePrimaryPageClose(launchedPage);
    } catch (error) {
      if (browser === launchedBrowser) {
        browser = undefined;
        context = undefined;
        page = undefined;
      }
      await awaitAndClose(undefined, launchedBrowser, async (owned) => {
        await owned.close();
      });
      throw error;
    }
    browser.on("disconnected", () => {
      browser = undefined;
      context = undefined;
      page = undefined;
      auxiliaryPage = undefined;
      paused = false;
      pauseGeneration += 1;
    });
  }
  if (!page) throw new Error("Browser tab is unavailable");
  return snapshot();
}

async function execute(code: string, expectedStateHash: string, expectedCodeHash: string, policyVersion: string, expiresAt: string): Promise<PageSnapshot | undefined> {
  if (!page) throw new Error("Browser tab is not running");
  return executeBrowserPlan(page, snapshot, code, expectedStateHash, expectedCodeHash, policyVersion, expiresAt);
}

function handlePrimaryPageClose(closedPage: Page): void {
  if (page !== closedPage) return;
  page = undefined;
  context = undefined;
  auxiliaryPage = undefined;
  paused = false;
  pauseGeneration += 1;
  lifecycleGeneration += 1;
  if (!shuttingDown) teardownInFlight = shutdown();
}

async function handle(command: Command): Promise<void> {
  if (command.type !== "stop" && teardownInFlight) {
    await teardownInFlight;
    teardownInFlight = undefined;
  }
  if (command.version !== PROTOCOL_VERSION || !command.session_id) {
    reply(command, false, { status: "idle" }, "protocol_invalid");
    return;
  }
  if (sessionID && command.session_id !== sessionID) {
    reply(command, false, { status: browser ? "running" : "idle" }, "session_mismatch");
    return;
  }
  if (command.deadline_ms !== undefined && Date.now() > command.deadline_ms) {
    reply(command, false, { status: browser ? (paused ? "paused" : "running") : "idle" }, "request_expired");
    return;
  }
  if (command.type === "start") sessionID = command.session_id;

  try {
    switch (command.type) {
      case "start": {
        const pageSnapshot = await withDeadline(command.deadline_ms, start, () => { lifecycleGeneration += 1; teardownInFlight = shutdown(); });
        reply(command, true, { status: "running", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "snapshot": {
        if (paused) {
          reply(command, true, { status: "paused" });
          return;
        }
        const pageSnapshot = await withDeadline(command.deadline_ms, snapshot, () => { lifecycleGeneration += 1; teardownInFlight = shutdown(); });
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
        const pageSnapshot = await withDeadline(command.deadline_ms, snapshot, () => { lifecycleGeneration += 1; teardownInFlight = shutdown(); });
        reply(command, true, { status: "running", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "execute": {
        const pageSnapshot = await withDeadline(
          command.deadline_ms,
          () => execute(command.code!, command.state_hash!, command.code_hash!, command.policy_version!, command.expires_at!),
          () => {
            lifecycleGeneration += 1;
            teardownInFlight = shutdown();
          },
        );
        reply(command, true, { status: "running", ...(pageSnapshot ? { snapshot: pageSnapshot } : {}) });
        return;
      }
      case "stop": {
        // Stop is a lifecycle barrier: cleanup must await an in-flight launch,
        // even if the original start request already timed out.
        await shutdown();
        paused = false;
        pauseGeneration += 1;
        sessionID = undefined;
        reply(command, true, { status: "stopped" });
        setImmediate(() => process.exit(0));
        return;
      }
    }
  } catch (error) {
    reply(command, false, { status: browser ? (paused ? "paused" : "running") : "idle" }, errorCategory(error));
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let commandQueue = Promise.resolve();
input.on("line", (line) => {
  try {
    const value: unknown = JSON.parse(line);
    if (!isCommand(value)) {
      reply(invalidCommand(value), false, { status: browser ? (paused ? "paused" : "running") : "idle" }, "protocol_invalid");
      return;
    }
    commandQueue = commandQueue.then(() => handle(value)).catch(() => undefined);
  } catch {
    process.stderr.write("Invalid sidecar command\n");
  }
});
const shutdown = async (): Promise<void> => {
  shuttingDown = true;
  lifecycleGeneration += 1;
  const ownedBrowser = browser;
  await awaitAndClose(launchInFlight, ownedBrowser, async (owned) => {
    await owned.close();
  });
  browser = undefined;
  context = undefined;
  page = undefined;
  auxiliaryPage = undefined;
};

input.on("close", () => {
  void shutdown().finally(() => process.exit(0));
});

process.on("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
process.on("SIGINT", () => void shutdown().finally(() => process.exit(0)));
