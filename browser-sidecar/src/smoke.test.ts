import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { awaitAndClose } from "./shutdown.js";

const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.ts"), "utf8");

test("sidecar package builds", () => {
  assert.equal(typeof process.version, "string");
});

test("shutdown awaits a pending browser launch", async () => {
  let resolveLaunch: (browser: object) => void = () => undefined;
  const launch = new Promise<object>((resolve) => { resolveLaunch = resolve; });
  const closed: object[] = [];
  let finished = false;
  const cleanup = awaitAndClose(launch, undefined, async (browser) => {
    closed.push(browser);
  }).then(() => { finished = true; });

  await Promise.resolve();
  assert.equal(finished, false);
  const browser = {};
  resolveLaunch(browser);
  await cleanup;
  assert.deepEqual(closed, [browser]);
  assert.equal(finished, true);
});

test("shutdown closes published ownership and does not double-close it", async () => {
  const browser = {};
  const closed: object[] = [];
  await Promise.all([
    awaitAndClose(Promise.resolve(browser), undefined, async (owned) => { closed.push(owned); }),
    awaitAndClose(undefined, browser, async (owned) => { closed.push(owned); }),
  ]);
  assert.deepEqual(closed, [browser]);
});

test("protocol stop uses the lifecycle shutdown barrier", () => {
  const stop = source.slice(source.indexOf('case "stop"'));
  assert.ok(stop.indexOf("await shutdown()") < stop.indexOf("reply(command, true"));
  assert.ok(stop.indexOf("reply(command, true") < stop.indexOf("process.exit(0)"));
});

test("failed browser initialization closes local ownership", () => {
  const initialization = source.slice(source.indexOf("const launchPromise"), source.indexOf("context.on(\"page\""));
  assert.ok(initialization.includes("browser = launchedBrowser"));
  assert.ok(initialization.includes("await awaitAndClose(undefined, launchedBrowser"));
});

test("expired commands are rejected before start claims the session", () => {
  const handle = source.slice(source.indexOf("async function handle"));
  assert.ok(handle.indexOf('"request_expired"') < handle.indexOf('if (command.type === "start") sessionID'));
});
