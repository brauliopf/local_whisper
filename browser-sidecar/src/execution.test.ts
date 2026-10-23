import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { executeBrowserPlan } from "./execution.js";
import type { PageSnapshot } from "./redaction.js";

const policy = "browser-interaction-v1";
const snapshot: PageSnapshot = { url: "https://example.com/", title: "Example", nodes: [], stateHash: "state-1" };
const hash = (code: string) => createHash("sha256").update(code).digest("hex");
const future = new Date(Date.now() + 60_000).toISOString();

function plan(code: string, page: object = {}) {
  return executeBrowserPlan(page as never, async () => snapshot, code, snapshot.stateHash, hash(code), policy, future);
}

test("rejects invalid hash, policy, stale state, and expiry before page execution", async () => {
  let pageCalls = 0;
  const page = { goto: () => { pageCalls += 1; } };
  const navigation = "await page.goto('https://example.com');";

  await assert.rejects(() => executeBrowserPlan(page as never, async () => snapshot, navigation, snapshot.stateHash, "wrong", policy, future), /code hash mismatch/);
  assert.equal(pageCalls, 0);

  const unsafe = "await page.constructor.constructor('return process')();";
  await assert.rejects(() => executeBrowserPlan(page as never, async () => snapshot, unsafe, snapshot.stateHash, hash(unsafe), policy, future), /policy violation/);
  assert.equal(pageCalls, 0);

  await assert.rejects(() => executeBrowserPlan(page as never, async () => ({ ...snapshot, stateHash: "new" }), navigation, snapshot.stateHash, hash(navigation), policy, future), /stale browser state/);
  assert.equal(pageCalls, 0);

  await assert.rejects(() => executeBrowserPlan(page as never, async () => snapshot, navigation, snapshot.stateHash, hash(navigation), policy, new Date(Date.now() - 1_000).toISOString()), /expired browser plan/);
  assert.equal(pageCalls, 0);
});

test("executes an approved plan and takes the post-execution snapshot", async () => {
  let navigated = false;
  const page = { goto: async () => { navigated = true; } };
  await plan("await page.goto('https://example.com');", page);
  assert.equal(navigated, true);
});

test("executes a generic multi-action semantic sequence once", async () => {
  const actions: string[] = [];
  const page = {
    getByRole: (role: string, options: { name: string }) => ({
      check: async () => { actions.push(`${role}:${options.name}:check`); },
      click: async () => { actions.push(`${role}:${options.name}:click`); },
    }),
  };
  const code = "await page.getByRole('checkbox', { name: 'Agree' }).check(); await page.getByRole('button', { name: 'Next' }).click();";
  await plan(code, page);
  assert.deepEqual(actions, ["checkbox:Agree:check", "button:Next:click"]);
});
