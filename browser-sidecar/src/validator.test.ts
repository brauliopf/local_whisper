import assert from "node:assert/strict";
import { test } from "node:test";
import { validateBrowserCode } from "./validator.js";

test("allows bounded navigation and interaction", () => {
  assert.equal(validateBrowserCode("await page.goto('https://example.test');").valid, true);
  assert.equal(validateBrowserCode("await page.getByRole('button').click();").valid, true);
  assert.equal(validateBrowserCode("await page.mouse.wheel(0, 1000);").valid, true);
});

test("rejects browser shutdown and runtime access", () => {
  const result = validateBrowserCode("await browser.close();");
  assert.equal(result.valid, false);
  assert.equal(result.violations.some((item) => item.category === "shutdown_or_runtime"), true);
  assert.equal(validateBrowserCode("await page.evaluate(() => window.scrollTo(0, 0));").valid, false);
});

test("rejects sensitive input", () => {
  const result = validateBrowserCode("await page.locator('password').fill('secret');");
  assert.equal(result.valid, false);
  assert.equal(result.violations.some((item) => item.category === "sensitive_input"), true);
});
