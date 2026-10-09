import type { Page } from "playwright";

const maxTextLength = 20_000;

export async function pageContext(page: Page): Promise<{ title: string; text: string }> {
  const title = await page.title().catch(() => "");
  const text = await page.locator("body").innerText({ timeout: 5_000 }).catch(() => "");
  return { title, text: text.trim().slice(0, maxTextLength) };
}

export async function saveScreenshot(
  page: Page,
  scope: "viewport" | "full_page" = "viewport",
): Promise<string> {
  const path = `/tmp/local-whisper-browser-${crypto.randomUUID()}.png`;
  await page.screenshot({ path, fullPage: scope === "full_page" });
  return path;
}
