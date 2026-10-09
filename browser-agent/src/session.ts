import { chromium, type BrowserContext, type Page } from "playwright";
import { pageContext, saveScreenshot } from "./context.js";

export class BrowserSession {
  private context?: BrowserContext;
  private page?: Page;

  async start(profilePath: string): Promise<void> {
    if (this.context) return;
    this.context = await chromium.launchPersistentContext(profilePath, {
      headless: false,
      viewport: null,
    });
    this.page = this.context.pages()[0] ?? await this.context.newPage();
  }

  async stop(): Promise<void> {
    await this.context?.close();
    this.context = undefined;
    this.page = undefined;
  }

  async navigate(url: string): Promise<void> {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error("Only HTTP and HTTPS URLs are supported");
    }
    await this.requirePage().goto(parsed.toString(), { waitUntil: "domcontentloaded" });
  }

  async inspect(): Promise<{ title: string; text: string }> {
    return pageContext(this.requirePage());
  }

  async screenshot(scope: "viewport" | "full_page" = "viewport"): Promise<string> {
    return saveScreenshot(this.requirePage(), scope);
  }

  async execute(action: { type: "click"; target: string } | { type: "scroll"; direction: "up" | "down" } | { type: "read"; target?: string } | { type: "wait"; milliseconds: number }): Promise<unknown> {
    const page = this.requirePage();
    switch (action.type) {
      case "click":
        await page.getByText(action.target, { exact: true }).first().click();
        return pageContext(page);
      case "scroll":
        await page.mouse.wheel(0, action.direction === "down" ? 700 : -700);
        return pageContext(page);
      case "read":
        return pageContext(page);
      case "wait":
        await new Promise((resolve) => setTimeout(resolve, action.milliseconds));
        return pageContext(page);
    }
  }

  private requirePage(): Page {
    if (!this.page) throw new Error("Browser session is not running");
    return this.page;
  }
}
