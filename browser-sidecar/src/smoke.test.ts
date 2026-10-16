import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { awaitAndClose } from "./shutdown.js";

const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.ts"), "utf8");
const executionSource = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "execution.ts"), "utf8");

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

test("accepts one auxiliary page without replacing the primary page", () => {
  assert.ok(source.includes("let auxiliaryPage: Page | undefined"));
  assert.ok(source.includes("if (!auxiliaryPage)"));
  assert.ok(source.includes("auxiliaryPage = newPage"));
  assert.ok(source.includes("if (auxiliaryPage === newPage) auxiliaryPage = undefined"));
  assert.ok(source.includes("newPage.close().catch"));
});

test("primary page closure invalidates ownership before browser teardown", () => {
  const closeHandler = source.slice(source.indexOf("function handlePrimaryPageClose"), source.indexOf("async function handle(command"));
  assert.ok(closeHandler.includes("if (page !== closedPage) return"));
  assert.ok(closeHandler.includes("page = undefined"));
  assert.ok(closeHandler.includes("lifecycleGeneration += 1"));
  assert.ok(closeHandler.includes("if (!shuttingDown) teardownInFlight = shutdown()"));
  assert.ok(source.includes('launchedPage.once("close", () => handlePrimaryPageClose(launchedPage))'));
});

test("request filtering keeps HTTP(S) checks without DNS blocking", () => {
  assert.equal(source.includes('launchedContext.route("**/*"'), true);
  assert.equal(source.includes("lookup("), false);
  assert.ok(source.includes("isSafeBrowserURL(rawURL)"));
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

test("execution validates hashes, policy, state, and expiry", () => {
  const execution = executionSource;
  assert.ok(execution.includes("code hash mismatch"));
  assert.ok(execution.includes("validateBrowserCode(code, policyVersion)"));
  assert.ok(execution.includes("stale browser state"));
  assert.ok(execution.includes("expired browser plan"));
});

test("execution timeout tears down browser ownership", () => {
  const executionCase = source.slice(source.indexOf('case "execute"'));
  assert.ok(executionCase.includes("lifecycleGeneration += 1"));
  assert.ok(executionCase.includes("void shutdown()"));
});
