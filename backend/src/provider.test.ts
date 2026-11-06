import assert from "node:assert/strict";
import { test } from "node:test";
import { OpenAIImageTextProvider } from "./provider.js";
import type { ConversationMessage } from "./memory.js";

test("extracts grounded entities with structured output and sorts embedding results", async () => {
  let extractionRequest: Record<string, unknown> | undefined;
  let embeddingInputs: string[] = [];
  const client = {
    responses: {
      async create(request: Record<string, unknown>) {
        extractionRequest = request;
        return {
          output_text: JSON.stringify({
            entities: [{
              name: "Lina",
              type: "PERSON",
              evidence: "I'll pick up Lina at school.",
            }],
          }),
        };
      },
    },
    embeddings: {
      async create(request: { input: string[] }) {
        embeddingInputs = request.input;
        return {
          data: [
            { index: 1, embedding: [2] },
            { index: 0, embedding: [1] },
          ],
        };
      },
    },
  } as unknown as ConstructorParameters<typeof OpenAIImageTextProvider>[0];
  const provider = new OpenAIImageTextProvider(client, "vision", "chat", "transcription", "translation");
  const signal = new AbortController().signal;
  const transcript = "I'll pick up Lina at school.";

  assert.deepEqual(await provider.extractEntities(transcript, signal), [{
    name: "Lina",
    type: "PERSON",
    evidence: transcript,
  }]);
  assert.equal(extractionRequest?.model, "gpt-4o-mini");
  assert.equal(extractionRequest?.input, transcript);
  assert.match(String(extractionRequest?.instructions), /unambiguous pronouns/);
  const text = extractionRequest?.text as { format?: { type?: string; strict?: boolean } };
  assert.equal(text.format?.type, "json_schema");
  assert.equal(text.format?.strict, true);
  assert.deepEqual(await provider.embedTexts(["first", "second"], signal), [[1], [2]]);
  assert.deepEqual(embeddingInputs, ["first", "second"]);
});

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
