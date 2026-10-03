import { access, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import vm from "node:vm";
import { chromium, type BrowserContext, type Page } from "playwright";
import {
  defaultScriptTimeoutMs,
  isAllowedOrigin,
  maxResultBytes,
  maxScriptBytes,
  originOf,
  parseConfiguration,
  type BrowserConfiguration,
  type ExecutorResult,
  type SessionInfo,
  type TableValue,
} from "./protocol.js";

class InvalidResultError extends Error {}
class NavigationPolicyError extends Error {}

export class BrowserExecutor {
  private context?: BrowserContext;
  private page?: Page;
  private configuration?: BrowserConfiguration;
  private screenshotNumber = 0;
  private policyError?: string;
  private extraPageError?: string;

  async start(rawConfiguration: unknown): Promise<SessionInfo> {
    if (this.context) throw new Error("Browser session is already running.");
    const configuration = parseConfiguration(rawConfiguration);
    if (!isAllowedOrigin(configuration.initialURL, configuration.allowedOrigins)) {
      throw new NavigationPolicyError("Initial URL is outside the allowed origins.");
    }

    this.configuration = configuration;
    try {
      await mkdir(configuration.profileDirectory, { recursive: true });
      const storageStatePath = join(configuration.profileDirectory, "storage-state.json");
      const hasStorageState = await access(storageStatePath).then(() => true).catch(() => false);
      this.context = await chromium.launchPersistentContext(configuration.profileDirectory, {
        headless: false,
        viewport: { width: 1440, height: 900 },
        ...(hasStorageState ? { storageState: storageStatePath } : {}),
      });
      this.context.setDefaultTimeout(10_000);
      this.context.setDefaultNavigationTimeout(15_000);
      this.context.on("page", page => {
        if (this.page && page !== this.page) {
          this.extraPageError = "Additional pages are not supported.";
          void page.close().catch(() => undefined);
        }
      });
      await this.context.cookies();
      const existingPages = this.context.pages();
      for (const page of existingPages) await page.close().catch(() => undefined);
      this.page = await this.context.newPage();
      this.page.on("framenavigated", frame => {
        if (frame !== this.page?.mainFrame() || frame.url() === "about:blank") return;
        if (!isAllowedOrigin(frame.url(), configuration.allowedOrigins)) {
          this.policyError = `Navigation outside the allowed origins: ${originOf(frame.url())}`;
          void this.page?.goto("about:blank").catch(() => undefined);
        }
      });
      await this.page.goto(configuration.initialURL, { waitUntil: "domcontentloaded" });
      if (hasStorageState) await this.page.reload({ waitUntil: "domcontentloaded" });
      return this.sessionInfo();
    } catch (error) {
      await this.stop();
      throw error;
    }
  }

  async execute(moduleCode: string): Promise<ExecutorResult> {
    const page = this.page;
    const context = this.context;
    const configuration = this.configuration;
    if (!page || !context || !configuration) throw new Error("Browser session is not running.");
    if (this.policyError) throw new NavigationPolicyError(this.policyError);
    if (this.extraPageError) throw new NavigationPolicyError(this.extraPageError);
    if (!moduleCode.trim() || Buffer.byteLength(moduleCode) > maxScriptBytes) {
      return this.scriptError("Script is empty or exceeds the 64 KiB limit.");
    }

    const artifacts: Array<{ path: string; mimeType: "image/png"; label: string }> = [];
    const screenshot = async (label: string) => {
      this.screenshotNumber += 1;
      await mkdir(configuration.artifactDirectory, { recursive: true });
      const safeLabel = label.replace(/[^a-z0-9-]/gi, "-").slice(0, 80);
      const path = join(configuration.artifactDirectory, `${String(this.screenshotNumber).padStart(3, "0")}-${safeLabel || "page"}.png`);
      await page.screenshot({ path });
      const artifact = { path, mimeType: "image/png" as const, label };
      artifacts.push(artifact);
      return artifact;
    };

    const run = this.runModule(moduleCode, page, context, screenshot);
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      const timedOut = new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error("Script timed out.")), configuration.scriptTimeoutMs ?? defaultScriptTimeoutMs);
      });
      const value = await Promise.race([run, timedOut]);
      if (this.policyError) throw new NavigationPolicyError(this.policyError);
      if (this.extraPageError) throw new NavigationPolicyError(this.extraPageError);
      if (Buffer.byteLength(JSON.stringify(value)) > maxResultBytes) throw new InvalidResultError("Script result exceeds the 4 MiB limit.");
      const table = normalizeTable(value);
      const automaticScreenshot = await screenshot("step");
      return { ok: true, value: table, text: [], artifacts, screenshot: automaticScreenshot, browser: await this.sessionInfo() };
    } catch (error) {
      if (error instanceof Error && error.message === "Script timed out.") {
        await this.stop();
        throw error;
      }
      if (this.policyError || this.extraPageError || error instanceof NavigationPolicyError) {
        const browser = await this.sessionInfo();
        const message = this.policyError ?? this.extraPageError ?? (error as Error).message;
        await this.stop();
        return { ok: false, error: { kind: "navigation_policy", message }, browser };
      }
      if (error instanceof InvalidResultError) return { ok: false, error: { kind: "invalid_result", message: error.message }, browser: await this.sessionInfo() };
      return this.scriptError(error instanceof Error ? error.message : String(error), await this.sessionInfo());
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  async stop(): Promise<void> {
    const configuration = this.configuration;
    if (configuration && this.context) {
      await mkdir(configuration.profileDirectory, { recursive: true });
      await this.context.storageState({ path: join(configuration.profileDirectory, "storage-state.json") }).catch(() => undefined);
    }
    await this.context?.close().catch(() => undefined);
    if (configuration) await rm(configuration.artifactDirectory, { recursive: true, force: true }).catch(() => undefined);
    this.page = undefined;
    this.context = undefined;
    this.configuration = undefined;
    this.policyError = undefined;
    this.extraPageError = undefined;
  }

  async clearProfile(): Promise<void> {
    const profileDirectory = this.configuration?.profileDirectory;
    await this.stop();
    if (profileDirectory) await rm(profileDirectory, { recursive: true, force: true }).catch(() => undefined);
  }

  private async runModule(
    moduleCode: string,
    page: Page,
    context: BrowserContext,
    screenshot: (label: string) => Promise<{ path: string; mimeType: "image/png"; label: string }>
  ) {
    const sandbox = vm.createContext({ page, context, screenshot });
    const script = new vm.Script(`(async () => {
      const module = { exports: {} };
      const exports = module.exports;
      ${moduleCode}
      if (typeof module.exports !== "function") throw new Error("Module must export a function.");
      return await module.exports({ page, context, screenshot });
    })()`, { filename: "generated-playwright-module.js" });
    return script.runInContext(sandbox);
  }

  private async sessionInfo(): Promise<SessionInfo> {
    return { url: this.page?.url() ?? "", title: this.page ? await this.page.title().catch(() => "") : "" };
  }

  private async scriptError(message: string, browser?: SessionInfo): Promise<ExecutorResult> {
    return { ok: false, error: { kind: "script_error", message }, browser: browser ?? await this.sessionInfo() };
  }
}

function normalizeTable(value: unknown): TableValue {
  if (!isRecord(value) || value.type !== "table" || !Array.isArray(value.columns) ||
    value.columns.some(item => typeof item !== "string") || !Array.isArray(value.rows) ||
    value.rows.some(row => !Array.isArray(row) || row.some(cell => typeof cell !== "string")) ||
    !Array.isArray(value.notes) || value.notes.some(item => typeof item !== "string")) {
    throw new InvalidResultError("Script must return a generic table value.");
  }
  return JSON.parse(JSON.stringify(value)) as TableValue;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
