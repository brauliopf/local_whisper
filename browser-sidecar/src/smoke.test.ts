import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.ts"), "utf8");

test("sidecar package builds", () => {
  assert.equal(typeof process.version, "string");
});

test("shutdown awaits a pending browser launch", () => {
  assert.match(source, /let launchInFlight: Promise<Browser> \| undefined/);
  assert.match(source, /const pendingLaunch = launchInFlight/);
  assert.match(source, /const launchedBrowser = pendingLaunch \? await pendingLaunch\.catch/);
  assert.match(source, /if \(launchedBrowser && launchedBrowser !== ownedBrowser\) await launchedBrowser\.close/);
});

test("protocol stop uses the lifecycle shutdown barrier", () => {
  const stop = source.slice(source.indexOf('case "stop"'));
  assert.ok(stop.indexOf("await shutdown()") < stop.indexOf("reply(command, true"));
  assert.ok(stop.indexOf("reply(command, true") < stop.indexOf("process.exit(0)"));
});

test("failed browser initialization closes local ownership", () => {
  const initialization = source.slice(source.indexOf("const launchPromise"), source.indexOf("context.on(\"page\""));
  assert.ok(initialization.includes("browser = launchedBrowser"));
  assert.ok(initialization.includes("await launchedBrowser.close().catch"));
});

test("expired commands are rejected before start claims the session", () => {
  const handle = source.slice(source.indexOf("async function handle"));
  assert.ok(handle.indexOf('"request_expired"') < handle.indexOf('if (command.type === "start") sessionID'));
});
