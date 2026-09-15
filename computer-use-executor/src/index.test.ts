import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("reports malformed JSON and continues processing requests", async () => {
  const child = spawn(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), "index.js")], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const output = createInterface({ input: child.stdout });
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += String(chunk); });
  const nextLine = () => new Promise<string>(resolve => output.once("line", resolve));

  try {
    child.stdin.write("{not valid JSON}\n");
    const parseError = JSON.parse(await nextLine()) as { id: unknown; error: { code: number } };
    assert.equal(parseError.id, null);
    assert.equal(parseError.error.code, -32700);

    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "session.stop", params: {} }) + "\n");
    const stopResponse = JSON.parse(await nextLine()) as { id: number; result: { stopped: boolean } };
    assert.equal(stopResponse.id, 1);
    assert.equal(stopResponse.result.stopped, true);
    await once(child, "exit");
    assert.match(stderr, /rejected stdin request/);
  } finally {
    output.close();
    if (!child.killed) child.kill();
  }
});
