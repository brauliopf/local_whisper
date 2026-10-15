import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { executeBrowserPlan } from "./execution.js";
import type { PageSnapshot } from "./redaction.js";

const policy = "browser-navigation-v1";
const snapshot: PageSnapshot = { url: "https://example.com/", title: "Example", controls: [], stateHash: "state-1" };
const hash = (code: string) => createHash("sha256").update(code).digest("hex");
const future = new Date(Date.now() + 60_000).toISOString();

function plan(code: string, page: object = {}) {
  return executeBrowserPlan(page as never, async () => snapshot, code, snapshot.stateHash, hash(code), policy, future);
}

test("rejects invalid hash, stale state, and expiry before page execution", async () => {
  const page = { goto: () => { throw new Error("must not execute"); } };
  await assert.rejects(() => executeBrowserPlan(page as never, async () => snapshot, "await page.goto('https://example.com');", snapshot.stateHash, "wrong", policy, future), /code hash mismatch/);
  await assert.rejects(() => executeBrowserPlan(page as never, async () => ({ ...snapshot, stateHash: "new" }), "await page.goto('https://example.com');", snapshot.stateHash, hash("await page.goto('https://example.com');"), policy, future), /stale browser state/);
  await assert.rejects(() => plan("await page.goto('https://example.com');", page), /must not execute|expired/);
  await assert.rejects(() => executeBrowserPlan(page as never, async () => snapshot, "await page.goto('https://example.com');", snapshot.stateHash, hash("await page.goto('https://example.com');"), policy, new Date(Date.now() - 1_000).toISOString()), /expired browser plan/);
});

test("executes an approved plan and takes the post-execution snapshot", async () => {
  let navigated = false;
  const page = { goto: async () => { navigated = true; } };
  await plan("await page.goto('https://example.com');", page);
  assert.equal(navigated, true);
});
