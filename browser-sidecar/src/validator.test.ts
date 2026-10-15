import assert from "node:assert/strict";
import test from "node:test";
import { BROWSER_POLICY_VERSION, validateBrowserCode } from "./validator.js";

test("allows public navigation and search scrolling", () => {
  assert.equal(validateBrowserCode("await page.goto('https://example.com');").valid, true);
  assert.equal(validateBrowserCode("await page.mouse.wheel(0, 1000);").valid, true);
  assert.equal(validateBrowserCode("await page.getByRole('searchbox').fill('Botero');").valid, true);
});

test("rejects unsupported constructs and indirect access", () => {
  for (const code of [
    "do { await page.goto('https://example.com'); } while (false);",
    "label: await page.goto('https://example.com');",
    "class Exploit {}",
    "page.foo.click();",
    "page['goto']('https://example.com');",
    "page.waitForFunction`document.body.innerText`;",
  ]) {
    assert.equal(validateBrowserCode(code).valid, false, code);
  }
});

test("rejects local, private, link-local, and non-http targets", () => {
  for (const url of [
    "http://localhost:3000",
    "http://127.0.0.1",
    "http://10.0.0.1",
    "http://172.16.0.1",
    "http://192.168.1.1",
    "http://169.254.169.254",
    "http://[::1]",
    "http://[fd00::1]",
    "file:///etc/passwd",
  ]) {
    assert.equal(validateBrowserCode(`await page.goto('${url}');`).valid, false, url);
  }
  assert.equal(validateBrowserCode("await page.goto('https://example.com');").valid, true);
});

test("rejects sensitive or non-search input", () => {
  assert.equal(validateBrowserCode("await page.locator('#f1').fill('secret');").valid, false);
  assert.equal(validateBrowserCode("await page.getByRole('textbox').fill('secret');").valid, false);
  assert.equal(validateBrowserCode("await page.getByRole('searchbox').fill(value);").valid, false);
});

test("requires the supported policy version", () => {
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", BROWSER_POLICY_VERSION).valid, true);
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", "old-policy").valid, false);
});
