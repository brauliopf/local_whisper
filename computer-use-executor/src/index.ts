import { createInterface } from "node:readline";
import { BrowserExecutor } from "./executor.js";
import { isRecord, type Request } from "./protocol.js";

const executor = new BrowserExecutor();

/*
 * Writes a JSON-RPC message to the standard output.
 * the caller reads stdout
 * keep diagnostics separate from the executor (stderr)
 */
function write(message: Record<string, unknown>) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function errorResponse(id: number | null, message: string, code = -32000) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

function parseRequest(value: unknown): Request {
  if (!isRecord(value) || value.jsonrpc !== "2.0" || typeof value.id !== "number" ||
    typeof value.method !== "string" || !["session.start", "script.execute", "session.stop"].includes(value.method)) {
    throw new Error("Invalid JSON-RPC request.");
  }
  return value as unknown as Request;
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
    request = parseRequest(JSON.parse(line));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[executor] rejected stdin request: ${message}`);
    errorResponse(null, message, message === "Invalid JSON-RPC request." ? -32600 : -32700);
    return;
  }
  queue = queue.then(() => handle(request)).catch(error => {
    console.error(`[executor] unhandled request error: ${error instanceof Error ? error.message : String(error)}`);
  });
});

async function shutdown() {
  await executor.stop();
  process.exit(0);
}

input.on("close", () => void shutdown());
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
