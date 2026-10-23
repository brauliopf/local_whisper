import test from "node:test";
import assert from "node:assert/strict";
import {
  buildPageSnapshot,
  isSensitiveControl,
  redactPageSnapshot,
  redactSemanticNode,
  redactText,
  sanitizeURL,
} from "./redaction.js";

test("redacts credentials and payment-like text", () => {
  const text = "Email me@example.com and use 4111 1111 1111 1111";
  assert.equal(redactText(text), "[REDACTED_IDENTITY] and use [REDACTED_PAYMENT]");
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
  assert.equal(redactText("password=hunter2 token:abc123 api_key=supersecret"), "[REDACTED_SECRET] [REDACTED_SECRET] [REDACTED_SECRET]");
});

test("sanitizes URLs without exposing query values", () => {
  assert.equal(sanitizeURL("https://example.test/path?token=secret#private"), "https://example.test/[REDACTED_PATH]?[REDACTED_QUERY]");
  assert.equal(sanitizeURL("https://example.test/session/very-long-secret-token-value"), "https://example.test/[REDACTED_PATH]");
  assert.equal(sanitizeURL("javascript:alert(1)"), "[REDACTED_URL]");
  assert.equal(sanitizeURL("about:blank#private"), "about:blank");
  assert.equal(sanitizeURL("about:srcdoc"), "[REDACTED_URL]");
});

test("preserves safe semantic fields and hides sensitive values", () => {
  const safe = redactSemanticNode({ kind: "input", role: "searchbox", label: "Search", value: "Portland" });
  assert.equal(safe.label, "Search");
  assert.equal(safe.value, "Portland");

  const sensitive = redactSemanticNode({ kind: "input", type: "password", name: "hunter2", label: "Password hunter2", value: "secret" });
  assert.equal(sensitive.value, "[REDACTED]");
  assert.equal(sensitive.label, "[REDACTED]");
  assert.equal(sensitive.name, "[REDACTED]");
});

test("redacts and bounds semantic page snapshots", () => {
  const snapshot = redactPageSnapshot({
    url: "https://example.test/account?token=secret",
    title: "Account",
    nodes: [
      { kind: "button", role: "button", name: "Next", text: "Next" },
      { kind: "input", type: "password", label: "Password", value: "secret" },
    ],
  });
  assert.equal(snapshot.url, "https://example.test/[REDACTED_PATH]?[REDACTED_QUERY]");
  assert.equal(snapshot.nodes[0]?.name, "Next");
  assert.equal(snapshot.nodes[1]?.value, "[REDACTED]");
  assert.equal(Buffer.byteLength(JSON.stringify(snapshot), "utf8") <= 64_000, true);
});

test("truncates oversized snapshots deterministically and hashes stable state", () => {
  const input = {
    url: "https://example.test/",
    title: "Fixture",
    nodes: Array.from({ length: 500 }, (_, index) => ({ kind: "p", text: `${index} ${"x".repeat(500)}` })),
  };
  const first = buildPageSnapshot(input);
  const second = buildPageSnapshot(input);
  assert.equal(first.truncated, true);
  assert.equal(Buffer.byteLength(JSON.stringify(first), "utf8") <= 64_000, true);
  assert.deepEqual(first, second);
});
