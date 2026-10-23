import assert from "node:assert/strict";
import test from "node:test";
import { BROWSER_POLICY_VERSION, validateBrowserCode } from "./validator.js";

const valid = (code: string) => validateBrowserCode(code, BROWSER_POLICY_VERSION);

test("allows public navigation and generic semantic actions", () => {
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(valid("await page.mouse.wheel(0, 1000);").valid, true);
  assert.equal(valid("await page.getByRole('checkbox', { name: 'Agree' }).check();").valid, true);
  assert.equal(valid("await page.getByRole('button', { name: 'Next' }).click();").valid, true);
  assert.equal(valid("await page.getByLabel('City').fill('Portland');").valid, true);
  assert.equal(valid("await page.getByRole('combobox', { name: 'State' }).selectOption('OR');").valid, true);
  assert.equal(valid("await page.getByText('Continue').click();").valid, true);
});

test("rejects unsupported constructs, shutdown APIs, and indirect access", () => {
  for (const code of [
    "do { await page.goto('https://example.com'); } while (false);",
    "label: await page.goto('https://example.com');",
    "class Exploit {}",
    "page.foo.click();",
    "page.close();",
    "page.context().close();",
    "page.browser().close();",
    "page.constructor.constructor('return process')();",
    "page['goto']('https://example.com');",
    "page.waitForFunction`document.body.innerText`;",
    "page.goto('https://example.com', { referer: 'https://user:pass@evil.example' });",
  ]) {
    assert.equal(valid(code).valid, false, code);
  }
});

test("rejects local, private, link-local, and non-http targets", () => {
  for (const url of [
    "http://localhost:3000",
    "http://localhost.",
    "http://127.0.0.1",
    "http://10.0.0.1",
    "http://172.16.0.1",
    "http://192.168.1.1",
    "http://169.254.169.254",
    "http://[::1]",
    "http://[::]",
    "http://[::0]",
    "http://[0:0:0:0:0:0:0:0]",
    "http://[::ffff:127.0.0.1]",
    "http://[::ffff:0:7f00:1]",
    "http://[::7f00:1]",
    "http://[ff02::1]",
    "http://[2001:db8::1]",
    "http://[fd00::1]",
    "http://255.255.255.255",
    "file:///etc/passwd",
  ]) {
    assert.equal(valid(`await page.goto('${url}');`).valid, false, url);
  }
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(valid("await page.goto('http://fdic.gov');").valid, true);
  assert.equal(valid("await page.goto('https://user:password@example.com');").valid, false);
});

test("allows generic literal interaction but rejects runtime values", () => {
  assert.equal(valid("await page.locator('#name').fill('Ada');").valid, true);
  assert.equal(valid("await page.getByRole('textbox').press('Tab');").valid, true);
  assert.equal(valid("await page.getByRole('textbox').fill(value);").valid, false);
  assert.equal(valid("await page.getByRole('checkbox').check('unexpected');").valid, false);
  assert.equal(valid("await page.getByRole('combobox').selectOption(option);").valid, false);
});

test("requires the supported interaction policy version", () => {
  assert.equal(valid("await page.goto('https://example.com');").valid, true);
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", "old-policy").valid, false);
  assert.equal(validateBrowserCode("await page.goto('https://example.com');", undefined as unknown as string).valid, false);
});
