import assert from "node:assert/strict";
import { access, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { BrowserExecutor } from "./executor.js";
import { isAllowedOrigin } from "./protocol.js";

test("wildcard policy permits HTTP(S) origins but rejects other schemes", () => {
  assert.equal(isAllowedOrigin("https://example.com/path", ["*"]), true);
  assert.equal(isAllowedOrigin("http://example.com/path", ["*"]), true);
  assert.equal(isAllowedOrigin("file:///tmp/page.html", ["*"]), false);
  assert.equal(isAllowedOrigin("javascript:alert(1)", ["*"]), false);
});

test("runs sequential modules in one page and returns generic tables", async () => {
  const server = createServer((_, response) => {
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><h1>Fixture flights</h1><button id="count" onclick="this.textContent = Number(this.textContent) + 1">0</button>`);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  const artifactDirectory = await mkdtemp(join(tmpdir(), "local-whisper-executor-"));
  const profileDirectory = await mkdtemp(join(tmpdir(), "local-whisper-profile-"));
  const executor = new BrowserExecutor();

  try {
    const session = await executor.start({
      initialURL: `${origin}/flights`,
      allowedOrigins: [origin],
      artifactDirectory,
      profileDirectory,
    });
    assert.equal(session.url, `${origin}/flights`);

    const first = await executor.execute(`module.exports = async ({ page }) => ({
      type: "table",
      columns: ["Heading", "Count"],
      rows: [[await page.locator("h1").textContent(), await page.locator("#count").textContent()]],
      notes: []
    });`);
    assert.equal(first.ok, true);
    if (first.ok) {
      assert.deepEqual(first.value.rows, [["Fixture flights", "0"]]);
      await access(first.screenshot.path);
      assert.equal(first.screenshot.path.startsWith(artifactDirectory), true);
    }

    const failed = await executor.execute(`module.exports = async () => { throw new Error("recoverable"); };`);
    assert.equal(failed.ok, false);
    if (!failed.ok) assert.equal(failed.error.kind, "script_error");

    const second = await executor.execute(`module.exports = async ({ page }) => {
      await page.goto(${JSON.stringify(`${origin}/flights?search=1`)});
      await page.locator("#count").click();
      await page.locator("#count").click();
      return { type: "table", columns: ["URL", "Count"], rows: [[page.url(), await page.locator("#count").textContent()]], notes: [] };
    };`);
    assert.equal(second.ok, true);
    if (second.ok) assert.deepEqual(second.value.rows, [[`${origin}/flights?search=1`, "2"]]);

    const blocked = await executor.execute(`module.exports = async ({ page }) => {
      await page.goto("https://example.com");
      return { type: "table", columns: [], rows: [], notes: [] };
    };`);
    assert.equal(blocked.ok, false);
    if (!blocked.ok) assert.equal(blocked.error.kind, "navigation_policy");
  } finally {
    await executor.stop();
    await assert.rejects(() => access(artifactDirectory));
    await rm(profileDirectory, { recursive: true, force: true });
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});

test("reuses authenticated browser state across executor restarts", async () => {
  const server = createServer((request, response) => {
    const authenticated = request.headers.cookie?.includes("session=authenticated") === true;
    response.writeHead(200, { "content-type": "text/html", "set-cookie": ["session=authenticated; Path=/"] });
    response.end(`<!doctype html><body>${authenticated ? "Signed in" : "Login required"}</body>`);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  const profileDirectory = await mkdtemp(join(tmpdir(), "local-whisper-auth-profile-"));
  const firstArtifacts = await mkdtemp(join(tmpdir(), "local-whisper-auth-artifacts-"));
  const secondArtifacts = await mkdtemp(join(tmpdir(), "local-whisper-auth-artifacts-"));
  const first = new BrowserExecutor();
  const second = new BrowserExecutor();

  try {
    await first.start({ initialURL: origin, allowedOrigins: [origin], artifactDirectory: firstArtifacts, profileDirectory });
    const firstResult = await first.execute(`module.exports = async ({ page }) => ({ type: "table", columns: ["State"], rows: [[await page.locator("body").textContent()]], notes: [] });`);
    assert.equal(firstResult.ok, true);
    await first.stop();

    await second.start({ initialURL: origin, allowedOrigins: [origin], artifactDirectory: secondArtifacts, profileDirectory });
    const secondResult = await second.execute(`module.exports = async ({ page }) => ({ type: "table", columns: ["State"], rows: [[await page.locator("body").textContent()]], notes: [] });`);
    assert.equal(secondResult.ok, true);
    if (secondResult.ok) assert.deepEqual(secondResult.value.rows, [["Signed in"]]);
    await second.clearProfile();
    await assert.rejects(() => access(profileDirectory));
  } finally {
    await first.stop();
    await second.stop();
    await rm(firstArtifacts, { recursive: true, force: true });
    await rm(secondArtifacts, { recursive: true, force: true });
    await rm(profileDirectory, { recursive: true, force: true });
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
