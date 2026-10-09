import { createInterface } from "node:readline";
import { BrowserSession } from "./session.js";
import type { BrowserRequest, BrowserResponse } from "./protocol.js";
import { isBrowserRequest } from "./protocol.js";

const session = new BrowserSession();
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });

function send(response: BrowserResponse): void {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

async function handle(request: BrowserRequest): Promise<void> {
  try {
    switch (request.type) {
      case "start":
        send({ id: request.id, type: "state", state: "starting" });
        await session.start(request.profilePath);
        send({ id: request.id, type: "state", state: "idle" });
        return;
      case "stop":
        await session.stop();
        send({ id: request.id, type: "state", state: "stopped" });
        return;
      case "navigate":
        await session.navigate(request.url);
        send({ id: request.id, type: "result", result: await session.inspect() });
        return;
      case "inspect":
        send({ id: request.id, type: "result", result: await session.inspect() });
        return;
      case "screenshot":
        send({ id: request.id, type: "result", result: { path: await session.screenshot(request.scope) } });
        return;
      case "execute":
        send({ id: request.id, type: "result", result: await session.execute(request.action) });
        return;
      case "shutdown":
        await session.stop();
        send({ id: request.id, type: "state", state: "stopped" });
        process.exit(0);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Browser operation failed";
    send({ id: request.id, type: "error", message });
  }
}

send({ id: "agent", type: "ready" });
input.on("line", (line) => {
  try {
    const value: unknown = JSON.parse(line);
    if (!isBrowserRequest(value)) throw new Error("Invalid browser request");
    void handle(value);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid browser request";
    send({ id: "unknown", type: "error", message });
  }
});
