import test from "node:test";
import assert from "node:assert/strict";
import { isSensitiveControl, redactControl, redactText, sanitizeURL } from "./redaction.js";

test("redacts credentials and payment-like text", () => {
  const text = "Email me@example.com and use 4111 1111 1111 1111";
  assert.equal(redactText(text), "Email [REDACTED_EMAIL] and use [REDACTED_PAYMENT]");
});

test("identifies sensitive controls from semantics", () => {
  assert.equal(isSensitiveControl({ type: "password" }), true);
  assert.equal(isSensitiveControl({ type: "email" }), true);
  assert.equal(isSensitiveControl({ autocomplete: "one-time-code" }), true);
  assert.equal(isSensitiveControl({ autocomplete: "cc-number" }), true);
  assert.equal(isSensitiveControl({ label: "Search" }), false);
});

test("redacts labeled identity and verification values", () => {
  assert.equal(redactText("Username: alice Email: alice@example.com OTP: 123456 Password: hunter2"), "[REDACTED_IDENTITY] [REDACTED_IDENTITY] [REDACTED_CODE] [REDACTED_SECRET]");
});

test("sanitizes URLs without exposing query values", () => {
  assert.equal(sanitizeURL("https://example.test/path?token=secret#private"), "https://example.test/[REDACTED_PATH]?[REDACTED_QUERY]");
  assert.equal(sanitizeURL("https://example.test/session/very-long-secret-token-value"), "https://example.test/[REDACTED_PATH]");
  assert.equal(sanitizeURL("javascript:alert(1)"), "[REDACTED_URL]");
});

test("preserves safe control values and hides sensitive values", () => {
  assert.equal(
    redactControl({ tag: "input", type: "text", label: "Search", value: "Portland" }).value,
    "Portland",
  );
  assert.equal(
    redactControl({ tag: "input", type: "password", label: "Password", value: "secret" }).value,
    "[REDACTED]",
  );
});
