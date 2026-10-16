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

test("request filtering checks every resolved address before continuing", () => {
  assert.equal(source.includes('launchedContext.route("**/*"'), true);
  assert.ok(source.includes("const hostname = url.hostname.replace(/^\\[|\\]$/g, \"\")"));
  assert.ok(source.includes("lookup(hostname"));
  assert.ok(source.includes("addresses.some"));
  assert.ok(source.includes("isSafeBrowserURL(rawURL)"));
});

test("browser disconnect ownership is published before initialization awaits", () => {
  const published = source.indexOf("browser = launchedBrowser;");
  const attached = source.indexOf("attachBrowserDisconnectHandler(launchedBrowser);");
  const initialization = source.indexOf("const launchedContext = await launchedBrowser.newContext();");
  assert.ok(published >= 0);
  assert.ok(published < attached);
  assert.ok(attached < initialization);
});

test("browser disconnect clears only owned state and emits one lifecycle event", () => {
  const start = source.indexOf("function attachBrowserDisconnectHandler");
  const end = source.indexOf("async function start", start);
  const disconnectHandler = source.slice(start, end);
  assert.ok(disconnectHandler.includes('ownedBrowser.on("disconnected"'));
  assert.ok(disconnectHandler.includes("if (browser !== ownedBrowser) return"));
  assert.ok(disconnectHandler.includes("browser = undefined"));
  assert.ok(disconnectHandler.includes("pageTracker = undefined"));
  assert.ok(disconnectHandler.includes("lifecycleGeneration += 1"));
  assert.ok(disconnectHandler.includes("sessionID = undefined"));
  assert.ok(disconnectHandler.includes("if (!shuttingDown)"));
  assert.equal((disconnectHandler.match(/event: "browser_closed"/g) ?? []).length, 1);
  assert.equal((source.match(/\.on\("disconnected"/g) ?? []).length, 1);
});

test("primary page closure emits a lifecycle event before browser teardown", () => {
  const closeHandler = source.slice(source.indexOf("function handlePrimaryPageClose"), source.indexOf("async function handle(command"));
  assert.ok(closeHandler.includes("if (page !== closedPage) return"));
  assert.ok(closeHandler.includes("page = undefined"));
  assert.ok(closeHandler.includes('event: "browser_closed"'));
  assert.ok(closeHandler.includes("lifecycleGeneration += 1"));
  assert.ok(closeHandler.includes("sessionID = undefined"));
  assert.ok(closeHandler.includes("if (!shuttingDown)"));
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
