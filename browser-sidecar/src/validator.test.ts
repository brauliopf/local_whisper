import assert from "node:assert/strict";
import test from "node:test";
import { BROWSER_POLICY_VERSION, validateBrowserCode } from "./validator.js";

const valid = (code: string) => validateBrowserCode(code, BROWSER_POLICY_VERSION);

test("allows public navigation and search scrolling", () => {
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(valid("await page.mouse.wheel(0, 1000);").valid, true);
  assert.equal(valid("await page.getByRole('searchbox').fill('Botero');").valid, true);
});

test("rejects unsupported constructs and indirect access", () => {
  for (const code of [
    "do { await page.goto('https://example.com'); } while (false);",
    "label: await page.goto('https://example.com');",
    "class Exploit {}",
    "page.foo.click();",
    "page.constructor.constructor('return process')();",
    "page['goto']('https://example.com');",
    "page.waitForFunction`document.body.innerText`;",
    "page.goto('https://example.com', { referer: 'https://user:pass@evil.example' });",
  ]) {
    assert.equal(valid(code).valid, false, code);
  }
});

test("allows private HTTP(S) targets but rejects unsafe URL forms", () => {
  for (const url of [
    "http://localhost:3000",
    "http://127.0.0.1",
    "http://10.0.0.1",
    "http://[::1]",
    "http://169.254.169.254",
  ]) {
    assert.equal(valid(`await page.goto('${url}');`).valid, true, url);
  }
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(valid("await page.goto('http://fdic.gov');").valid, true);
  assert.equal(valid("await page.goto('file:///etc/passwd');").valid, false);
  assert.equal(valid("await page.goto('https://user:password@example.com');").valid, false);
});

test("rejects sensitive or non-search input", () => {
  assert.equal(valid("await page.locator('#f1').fill('secret');").valid, false);
  assert.equal(valid("await page.getByRole('textbox').fill('secret');").valid, false);
  assert.equal(valid("await page.getByRole('searchbox').fill(value);").valid, false);
  assert.equal(valid("await page.locator('#password').press('a');").valid, false);
  assert.equal(valid("await page.locator('input[type=search] + input[type=password]').fill('secret');").valid, false);
  assert.equal(valid("await page.getByRole('searchbox').press(key);").valid, false);
});

test("requires the supported policy version", () => {
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", "old-policy").valid, false);
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", undefined as unknown as string).valid, false);
});
