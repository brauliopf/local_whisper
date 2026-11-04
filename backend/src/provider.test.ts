import assert from "node:assert/strict";
import { test } from "node:test";
import { OpenAIImageTextProvider } from "./provider.js";
import type { ConversationMessage } from "./memory.js";

test("sends conversation history as role-tagged Responses input messages", async () => {
  let requestInput: unknown;
  const client = {
    responses: {
      async create({ input }: { input: unknown }) {
        requestInput = input;
        return { output_text: "They remembered." };
      },
    },
  } as unknown as ConstructorParameters<typeof OpenAIImageTextProvider>[0];
  const provider = new OpenAIImageTextProvider(client, "vision", "chat", "transcription", "translation");
  const messages: ConversationMessage[] = [
    { role: "user", content: "My name is Ada." },
    { role: "assistant", content: "Nice to meet you, Ada." },
    { role: "user", content: "What is my name?" },
  ];

  assert.equal(await provider.completeText(messages, new AbortController().signal), "They remembered.");
  assert.deepEqual(requestInput, messages);
});
