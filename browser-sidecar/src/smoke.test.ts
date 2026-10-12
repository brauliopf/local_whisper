import test from "node:test";
import assert from "node:assert/strict";

test("sidecar package builds", () => {
  assert.equal(typeof process.version, "string");
});
