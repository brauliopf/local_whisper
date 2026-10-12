import test from "node:test";
import assert from "node:assert/strict";
import { isSensitiveControl, redactControl, redactText } from "./redaction.js";

test("redacts credentials and payment-like text", () => {
  const text = "Email me@example.com and use 4111 1111 1111 1111";
  assert.equal(redactText(text), "Email [REDACTED_EMAIL] and use [REDACTED_PAYMENT]");
});

test("identifies sensitive controls from semantics", () => {
  assert.equal(isSensitiveControl({ type: "password" }), true);
  assert.equal(isSensitiveControl({ autocomplete: "one-time-code" }), true);
  assert.equal(isSensitiveControl({ label: "Search" }), false);
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
