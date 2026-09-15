import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { BrowserExecutor } from "./executor.js";

test("runs sequential modules in one page and returns generic tables", async () => {
  const server = createServer((_, response) => {
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><h1>Fixture flights</h1><button id="count" onclick="this.textContent = Number(this.textContent) + 1">0</button>`);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  const executor = new BrowserExecutor();

  try {
    const session = await executor.start({
      initialURL: `${origin}/flights`,
      allowedOrigins: [origin],
      artifactDirectory: await mkdtemp(join(tmpdir(), "local-whisper-executor-")),
    });
    assert.equal(session.url, `${origin}/flights`);

    const first = await executor.execute(`module.exports = async ({ page }) => ({
      type: "table",
      columns: ["Heading", "Count"],
      rows: [[await page.locator("h1").textContent(), await page.locator("#count").textContent()]],
      notes: []
    });`);
    assert.equal(first.ok, true);
    if (first.ok) assert.deepEqual(first.value.rows, [["Fixture flights", "0"]]);

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
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
