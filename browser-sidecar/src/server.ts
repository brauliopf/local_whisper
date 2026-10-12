import { createInterface } from "node:readline";

type Command = { id: string; type: "ping" | "stop" };

function reply(id: string, ok: boolean, error?: string): void {
  process.stdout.write(`${JSON.stringify({ id, ok, ...(error ? { error } : {}) })}\n`);
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  try {
    const command = JSON.parse(line) as Command;
    if (command.type === "ping") {
      reply(command.id, true);
    } else if (command.type === "stop") {
      reply(command.id, true);
      process.exit(0);
    }
  } catch {
    process.stderr.write("Invalid sidecar command\n");
  }
});
