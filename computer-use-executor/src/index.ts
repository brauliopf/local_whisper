import { createInterface } from "node:readline";
import { BrowserExecutor } from "./executor.js";
import { isRecord, type Request } from "./protocol.js";

const executor = new BrowserExecutor();

function write(message: Record<string, unknown>) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function errorResponse(id: number, message: string) {
  write({ jsonrpc: "2.0", id, error: { code: -32000, message } });
}

async function handle(request: Request) {
  try {
    switch (request.method) {
      case "session.start":
        write({ jsonrpc: "2.0", id: request.id, result: await executor.start(request.params) });
        return;
      case "script.execute": {
        if (!isRecord(request.params) || typeof request.params.module !== "string") throw new Error("script.execute requires module.");
        write({ jsonrpc: "2.0", id: request.id, result: await executor.execute(request.params.module) });
        return;
      }
      case "session.stop":
        await executor.stop();
        write({ jsonrpc: "2.0", id: request.id, result: { stopped: true } });
        setImmediate(() => process.exit(0));
        return;
    }
  } catch (error) {
    errorResponse(request.id, error instanceof Error ? error.message : String(error));
  }
}

let queue = Promise.resolve();
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", line => {
  if (!line.trim()) return;
  let request: Request;
  try {
    request = JSON.parse(line) as Request;
  } catch {
    errorResponse(0, "Invalid JSON request.");
    return;
  }
  queue = queue.then(() => handle(request)).catch(() => undefined);
});

async function shutdown() {
  await executor.stop();
  process.exit(0);
}

input.on("close", () => void shutdown());
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
