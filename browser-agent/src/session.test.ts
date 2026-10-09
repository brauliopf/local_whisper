import test from "node:test";
import assert from "node:assert/strict";
import { isBrowserRequest } from "./protocol.js";

test("accepts version-one start requests", () => {
  assert.equal(isBrowserRequest({ id: "1", type: "start", profilePath: "/tmp/profile" }), true);
});

test("rejects malformed protocol values", () => {
  assert.equal(isBrowserRequest({ type: "start" }), false);
  assert.equal(isBrowserRequest(null), false);
});
