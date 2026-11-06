import assert from "node:assert/strict";
import { test } from "node:test";
import type { AppConfig } from "./config.js";
import { buildApp, type AppDependencies } from "./app.js";
import type { BackendProvider, ExtractedEntity } from "./provider.js";
import { TranscriptionWorkflow } from "./transcription.js";
import {
  MemoryPersistenceError,
  type ConversationMessage,
  type ConversationStore,
} from "./memory.js";
import { ProviderFailureError } from "./errors.js";
import { defaultAccountId, EntityMemoryService } from "./entity-memory.js";

const serviceToken = "test-service-token";
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]);
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xd9]);
const m4a = Buffer.from([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41]);

const config: AppConfig = {
  port: 8080,
  openAIAPIKey: "not-used-in-tests",
  serviceToken,
  typesafeAPIKey: "test-typesafe-key",
  imageTextModel: "gpt-4o-mini",
  encouragementModel: "gpt-4o-mini",
  transcriptionModel: "whisper-1",
  translationModel: "gpt-4o-mini",
  typesafeModel: "jev-1.13.0",
  conversationStoreURL: "",
  conversationStoreSecretKey: "",
  imageMaxBytes: 10 * 1024 * 1024,
  audioMaxBytes: 25 * 1024 * 1024,
  requestBodyMaxBytes: 27 * 1024 * 1024,
  providerTimeoutMs: 100,
  overallTimeoutMs: 150,
  transcriptionProviderTimeoutMs: 70,
  transcriptionOverallTimeoutMs: 105,
  typesafeProviderTimeoutMs: 5,
  translationProviderTimeoutMs: 25,
  transcriptMaxChars: 20_000,
  rateLimitMax: 10,
  rateLimitWindowMs: 60_000,
};

class RecordingConversationStore implements ConversationStore {
  readonly writes: Array<{
    conversationId: string;
    role?: "user" | "assistant";
    content?: string;
  }> = [];
  readonly messages: ConversationMessage[] = [];
  readonly loads: string[] = [];
  readonly entityWrites: Array<{ accountId: string; entities: unknown[] }> = [];

  async ensureConversation(conversationId: string): Promise<void> {
    this.writes.push({ conversationId });
  }

  async loadMessages(conversationId: string): Promise<ConversationMessage[]> {
    this.loads.push(conversationId);
    return this.messages.map((message) => ({ ...message }));
  }

  async appendMessage(
    conversationId: string,
    role: "user" | "assistant",
    content: string,
  ): Promise<void> {
    this.writes.push({ conversationId, role, content });
    this.messages.push({ role, content });
  }

  async appendEntities(accountId: string, entities: unknown[]): Promise<void> {
    this.entityWrites.push({ accountId, entities });
  }
}

function delayWithAbort(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timeout);
      reject(new Error("operation aborted"));
    };
    const timeout = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    if (signal?.aborted) {
      onAbort();
    } else {
      signal?.addEventListener("abort", onAbort, { once: true });
    }
  });
}

class SlowUserMessageStore extends RecordingConversationStore {
  override async appendMessage(
    conversationId: string,
    role: "user" | "assistant",
    content: string,
    signal?: AbortSignal,
  ): Promise<void> {
    if (role === "user") await delayWithAbort(160, signal);
    await super.appendMessage(conversationId, role, content);
  }
}

class FailingConversationStore extends RecordingConversationStore {
  override async appendMessage(
    conversationId: string,
    role: "user" | "assistant",
    content: string,
  ): Promise<void> {
    if (role === "assistant") throw new MemoryPersistenceError(500);
    await super.appendMessage(conversationId, role, content);
  }
}

class FakeProvider implements BackendProvider {
  completeCalls = 0;

  constructor(
    private readonly result: string | null = "Hello\\nworld",
    private readonly transcriptionResult = "This is a test transcript.",
  ) {}

  async extractText(): Promise<string | null> {
    return this.result;
  }

  async generateEncouragement(): Promise<string> {
    return "Keep going—you are making progress.";
  }

  async transcribeAudio(): Promise<string> {
    return this.transcriptionResult;
  }

  async translateToEnglish(text: string): Promise<string> {
    return text;
  }

  readonly receivedMessages: ConversationMessage[][] = [];

  async extractEntities() {
    return [];
  }

  async embedTexts() {
    return [];
  }

  async completeText(messages: ConversationMessage[], _signal?: AbortSignal): Promise<string> {
    this.completeCalls += 1;
    this.receivedMessages.push(messages.map((message) => ({ ...message })));
    const latestUserMessage = [...messages].reverse().find(({ role }) => role === "user");
    return `Answer: ${latestUserMessage?.content ?? ""}`;
  }
}

const alwaysEnglishClassifier = {
  async judgeMajorityEnglish() {
    return { model: "test-jev", probability: 1 };
  },
};

function createTranscriptionWorkflow(provider: BackendProvider) {
  return new TranscriptionWorkflow({
    transcriber: provider,
    translator: provider,
    classifier: alwaysEnglishClassifier,
    transcriptionTimeoutMs: config.transcriptionProviderTimeoutMs,
    typesafeTimeoutMs: config.typesafeProviderTimeoutMs,
    translationTimeoutMs: config.translationProviderTimeoutMs,
    maxTranscriptChars: config.transcriptMaxChars,
  });
}

function multipartBody(
  data: Buffer,
  contentType = "image/jpeg",
  fieldName = "image",
  filename = "screenshot.jpg",
) {
  const boundary = "test-boundary";
  const prefix = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="${fieldName}"; filename="${filename}"\r\nContent-Type: ${contentType}\r\n\r\n`,
  );
  const suffix = Buffer.from(`\r\n--${boundary}--\r\n`);
  return {
    body: Buffer.concat([prefix, data, suffix]),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}

async function createTestApp(
  provider: BackendProvider = new FakeProvider(),
  conversationStore?: ConversationStore,
  configOverrides: Partial<AppConfig> = {},
  entityMemory?: Pick<EntityMemoryService, "recordTurn">,
  logger?: AppDependencies["logger"],
) {
  return buildApp({
    config: { ...config, ...configOverrides },
    provider,
    transcriptionWorkflow: createTranscriptionWorkflow(provider),
    conversationStore,
    entityMemory,
    logger,
  });
}

test("status does not require authentication", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({ method: "GET", url: "/status" });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), {
      status: "ok",
      providers: {
        openai: { configured: true },
        typesafe: { configured: true },
      },
    });
    assert.match(String(response.headers["x-request-id"] ?? ""), /^[0-9a-f-]{36}$/);
  } finally {
    await app.close();
  }
});

test("status reports an optional TypeSafe key as unconfigured", async () => {
  const app = await buildApp({
    config: { ...config, typesafeAPIKey: "" },
    provider: new FakeProvider(),
    transcriptionWorkflow: createTranscriptionWorkflow(new FakeProvider()),
  });
  try {
    const response = await app.inject({ method: "GET", url: "/status" });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json().providers, {
      openai: { configured: true },
      typesafe: { configured: false },
    });
  } finally {
    await app.close();
  }
});

test("extracts image text with a request id", async () => {
  const app = await createTestApp();
  const request = multipartBody(jpeg);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/image-text",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    const body = response.json();
    assert.equal(body.text, "Hello\\nworld");
    assert.equal(body.request_id, String(response.headers["x-request-id"]));
  } finally {
    await app.close();
  }
});

test("rejects requests without the service token", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({ method: "POST", url: "/image-text" });
    assert.equal(response.statusCode, 401);
    assert.equal(response.json().error.code, "authentication_failed");
    assert.equal(response.json().request_id, String(response.headers["x-request-id"]));
  } finally {
    await app.close();
  }
});

test("returns null for images with no readable text", async () => {
  const app = await createTestApp(new FakeProvider(null));
  const request = multipartBody(jpeg);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/image-text",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, null);
  } finally {
    await app.close();
  }
});

test("accepts PNG uploads", async () => {
  const app = await createTestApp();
  const request = multipartBody(png, "image/png");
  try {
    const response = await app.inject({
      method: "POST",
      url: "/image-text",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Hello\\nworld");
  } finally {
    await app.close();
  }
});

test("returns an encouragement", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({
      method: "POST",
      url: "/encouragements",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: "{}",
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Keep going—you are making progress.");
    assert.equal(response.json().request_id, String(response.headers["x-request-id"]));
  } finally {
    await app.close();
  }
});

test("transcribes M4A audio", async () => {
  const app = await createTestApp();
  const request = multipartBody(m4a, "audio/mp4", "audio", "recording.m4a");
  try {
    const response = await app.inject({
      method: "POST",
      url: "/transcriptions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), {
      text: "This is a test transcript.",
      is_translated: false,
      request_id: String(response.headers["x-request-id"]),
    });
  } finally {
    await app.close();
  }
});

test("returns a raw source-language transcription", async () => {
  const app = await createTestApp(new FakeProvider("Hello\\nworld", "Bonjour le monde."));
  const request = multipartBody(m4a, "audio/mp4", "audio", "recording.m4a");
  try {
    const response = await app.inject({
      method: "POST",
      url: "/source-transcriptions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Bonjour le monde.");
    assert.equal(response.json().request_id, String(response.headers["x-request-id"]));
  } finally {
    await app.close();
  }
});

test("completes transcript text without accepting audio", async () => {
  const provider = new FakeProvider();
  const store = new RecordingConversationStore();
  const app = await createTestApp(provider, store);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "What is the answer?" }),
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Answer: What is the answer?");
    assert.equal(response.json().request_id, String(response.headers["x-request-id"]));
    assert.deepEqual(provider.receivedMessages, [[
      { role: "user", content: "What is the answer?" },
    ]]);
    assert.deepEqual(store.loads, []);
  } finally {
    await app.close();
  }
});

test("loads conversation history into the completion request", async () => {
  const provider = new FakeProvider();
  const conversationStore = new RecordingConversationStore();
  conversationStore.messages.push(
    { role: "user", content: "What is the capital of France?" },
    { role: "assistant", content: "Paris." },
  );
  const app = await createTestApp(provider, conversationStore);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "what is cearense?", conversation_id: "conversation-1" }),
    });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(conversationStore.writes, [
      { conversationId: "conversation-1" },
      { conversationId: "conversation-1", role: "user", content: "what is cearense?" },
      { conversationId: "conversation-1", role: "assistant", content: "Answer: what is cearense?" },
    ]);
    assert.deepEqual(conversationStore.loads, ["conversation-1"]);
    assert.deepEqual(provider.receivedMessages, [[
      { role: "user", content: "What is the capital of France?" },
      { role: "assistant", content: "Paris." },
      { role: "user", content: "what is cearense?" },
    ]]);
    assert.equal(response.json().conversation_id, "conversation-1");
  } finally {
    await app.close();
  }
});

test("stores only exact, contextual entity evidence and preserves duplicates", async () => {
  const evidence = "Lina is my daughter. I'll pick her up at school every day.";
  const stripeEvidence = "Stripe account runs on sk_live_abcdefghijk.";
  const stripeTestEvidence = "Stripe test account uses sk_test_abcdefghijk.";
  const apiKeyEvidence = "Lina's API key is sk" + "-abcdefghijk";
  const text = `${evidence} After her mom puts her to bed, I'll review. ${apiKeyEvidence}. ${stripeEvidence} ${stripeTestEvidence}`;
  const entity = { name: "Lina", type: "PERSON" as const, evidence };
  let extractedText = "";
  let embeddedTexts: string[] = [];
  const store = new RecordingConversationStore();
  const service = new EntityMemoryService(
    {
      async extractEntities(input): Promise<ExtractedEntity[]> {
        extractedText = input;
        return [
          entity,
          entity,
          { name: "Lina", type: "PERSON", evidence: "Lina." },
          { name: "Lina's mom", type: "PERSON", evidence: "her mom puts her to bed" },
          { name: "Lina", type: "PERSON", evidence: apiKeyEvidence },
          { name: "Stripe", type: "ORGANIZATION", evidence: stripeEvidence },
          { name: "Stripe", type: "ORGANIZATION", evidence: stripeTestEvidence },
          { name: "Unknown", type: "PERSON", evidence: "not in the transcript" },
        ];
      },
      async embedTexts(inputs) {
        embeddedTexts = inputs;
        return inputs.map(() => Array(1536).fill(0));
      },
    },
    store,
  );

  await service.recordTurn(text, new AbortController().signal);

  assert.equal(extractedText, text);
  assert.deepEqual(embeddedTexts, [
    `Lina (PERSON): ${evidence}`,
    `Lina (PERSON): ${evidence}`,
  ]);
  assert.equal(store.entityWrites.length, 1);
  assert.equal(store.entityWrites[0]?.accountId, defaultAccountId);
  assert.deepEqual(store.entityWrites[0]?.entities, [
    { name: "Lina", type: "PERSON", description: evidence, embedding: Array(1536).fill(0) },
    { name: "Lina", type: "PERSON", description: evidence, embedding: Array(1536).fill(0) },
  ]);
});

test("does not persist incomplete entity embeddings", async () => {
  const store = new RecordingConversationStore();
  const service = new EntityMemoryService(
    {
      async extractEntities(): Promise<ExtractedEntity[]> {
        return [{ name: "Lina", type: "PERSON", evidence: "I'll pick up Lina." }];
      },
      async embedTexts() {
        return [[0.25]];
      },
    },
    store,
  );

  await assert.rejects(service.recordTurn("I'll pick up Lina.", new AbortController().signal));
  assert.equal(store.entityWrites.length, 0);
});

test("rejects client-supplied account IDs before any chat persistence or memory work", async () => {
  const provider = new FakeProvider();
  const store = new RecordingConversationStore();
  let memoryCalls = 0;
  const app = await createTestApp(provider, store, {}, {
    async recordTurn() {
      memoryCalls += 1;
    },
  });
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "Pick up Lina.", account_id: defaultAccountId }),
    });

    assert.equal(response.statusCode, 400);
    assert.deepEqual(store.writes, []);
    assert.equal(memoryCalls, 0);
    assert.equal(provider.completeCalls, 0);
  } finally {
    await app.close();
  }
});

test("runs entity memory on the current turn before completion and continues on failure", async () => {
  const events: string[] = [];
  const logLines: string[] = [];
  const provider = new FakeProvider();
  const store = new RecordingConversationStore();
  store.messages.push(
    { role: "user", content: "Old user message." },
    { role: "assistant", content: "Old assistant response." },
  );
  provider.completeText = async (messages) => {
    events.push("completion");
    provider.completeCalls += 1;
    provider.receivedMessages.push(messages);
    return "Done.";
  };
  const app = await createTestApp(
    provider,
    store,
    { overallTimeoutMs: 6_000 },
    {
      async recordTurn(text) {
        events.push(`memory:${text}`);
        throw new Error(`sensitive exception: ${text}`);
      },
    },
    { level: "warn", stream: { write: (message) => logLines.push(message) } },
  );
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "Pick up Lina at school.", conversation_id: "conversation-1" }),
    });
    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Done.");
    assert.deepEqual(events, ["memory:Pick up Lina at school.", "completion"]);
    const logs = logLines.join("");
    assert.match(logs, /entity_memory_failed/);
    assert.equal(logs.includes("Pick up Lina at school."), false);
    assert.equal(logs.includes("sensitive exception"), false);
    assert.deepEqual(provider.receivedMessages[0], [
      { role: "user", content: "Old user message." },
      { role: "assistant", content: "Old assistant response." },
      { role: "user", content: "Pick up Lina at school." },
    ]);
  } finally {
    await app.close();
  }
});

test("bounds entity memory and leaves the provider completion budget available", async () => {
  const events: string[] = [];
  const provider = new FakeProvider();
  provider.completeText = async (_messages, signal) => {
    events.push("completion");
    await delayWithAbort(400, signal);
    return "Done.";
  };
  const app = await createTestApp(provider, new RecordingConversationStore(), {
    providerTimeoutMs: 500,
    overallTimeoutMs: 5_600,
  }, {
    async recordTurn(_text, signal) {
      events.push("memory");
      try {
        await delayWithAbort(300, signal);
      } catch {
        events.push("memory-aborted");
        throw new Error("entity operation timed out");
      }
    },
  });
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "Pick up Lina." }),
    });

    assert.equal(response.statusCode, 200);
    assert.equal(response.json().text, "Done.");
    assert.deepEqual(events, ["memory", "memory-aborted", "completion"]);
  } finally {
    await app.close();
  }
});

test("persists the user message before the assistant message", async () => {
  const conversationStore = new RecordingConversationStore();
  const app = await createTestApp(new FakeProvider(), conversationStore);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "what is cearense?", conversation_id: "conversation-1" }),
    });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(conversationStore.writes, [
      { conversationId: "conversation-1" },
      { conversationId: "conversation-1", role: "user", content: "what is cearense?" },
      { conversationId: "conversation-1", role: "assistant", content: "Answer: what is cearense?" },
    ]);
    assert.equal(response.json().conversation_id, "conversation-1");
  } finally {
    await app.close();
  }
});

test("enforces one deadline across chat persistence and provider work", async () => {
  const provider = new FakeProvider();
  provider.completeText = async (text, signal) => {
    provider.completeCalls += 1;
    await delayWithAbort(160, signal);
    const latestUserMessage = [...text].reverse().find(({ role }) => role === "user");
    return `Answer: ${latestUserMessage?.content ?? ""}`;
  };
  const store = new SlowUserMessageStore();
  const app = await createTestApp(provider, store, {
    providerTimeoutMs: 1_000,
    overallTimeoutMs: 250,
  });
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "hello", conversation_id: "conversation-timeout" }),
    });
    assert.equal(response.statusCode, 504);
    assert.equal(response.json().error.code, "provider_timeout");
    assert.equal(provider.completeCalls, 1);
    assert.deepEqual(store.writes, [
      { conversationId: "conversation-timeout" },
      { conversationId: "conversation-timeout", role: "user", content: "hello" },
    ]);
  } finally {
    await app.close();
  }
});

test("logs the persistence operation when its deadline expires", async () => {
  const logs: string[] = [];
  const provider = new FakeProvider();
  const store = new SlowUserMessageStore();
  const app = await buildApp({
    config: { ...config, providerTimeoutMs: 1_000, overallTimeoutMs: 50 },
    provider,
    transcriptionWorkflow: createTranscriptionWorkflow(provider),
    conversationStore: store,
    logger: { level: "error", stream: { write: (message) => logs.push(message) } },
  });
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "private prompt", conversation_id: "conversation-timeout" }),
    });
    assert.equal(response.statusCode, 504);
    const failureLog = logs.map((message) => JSON.parse(message))
      .find((entry: { msg?: string }) => entry.msg === "request_failed");
    assert.equal(failureLog?.operation, "user_message_write");
    assert.equal(logs.join("").includes("private prompt"), false);
  } finally {
    await app.close();
  }
});

test("rejects conversation IDs that exceed the storage index limit", async () => {
  const provider = new FakeProvider();
  const store = new RecordingConversationStore();
  const app = await createTestApp(provider, store);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "hello", conversation_id: "x".repeat(1025) }),
    });
    assert.equal(response.statusCode, 400);
    assert.equal(response.json().error.code, "invalid_input");
    assert.equal(provider.completeCalls, 0);
    assert.deepEqual(store.writes, []);
  } finally {
    await app.close();
  }
});

test("fails chat before provider work when conversation persistence is not configured", async () => {
  const provider = new FakeProvider();
  const app = await createTestApp(provider);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "what is cearense?" }),
    });
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().error.code, "conversation_store_unavailable");
    assert.equal(provider.completeCalls, 0);
  } finally {
    await app.close();
  }
});

test("keeps the user message when the provider fails", async () => {
  const provider = new FakeProvider();
  provider.completeText = async () => { throw new ProviderFailureError(); };
  const store = new RecordingConversationStore();
  const app = await createTestApp(provider, store);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "what is cearense?" }),
    });
    assert.equal(response.statusCode, 502);
    const conversationId = String(response.headers["x-request-id"]);
    assert.deepEqual(store.writes, [
      { conversationId },
      { conversationId, role: "user", content: "what is cearense?" },
    ]);
  } finally {
    await app.close();
  }
});

test("does not return a completion when assistant-message persistence fails", async () => {
  const store = new FailingConversationStore();
  const app = await createTestApp(new FakeProvider(), store);
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "what is cearense?" }),
    });
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().error.code, "memory_persistence_failed");
    const conversationId = String(response.headers["x-request-id"]);
    assert.deepEqual(store.writes, [
      { conversationId },
      { conversationId, role: "user", content: "what is cearense?" },
    ]);
  } finally {
    await app.close();
  }
});

test("rejects empty chat completion input", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({
      method: "POST",
      url: "/chat-completions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ text: "   " }),
    });
    assert.equal(response.statusCode, 400);
    assert.equal(response.json().error.code, "invalid_input");
  } finally {
    await app.close();
  }
});

test("preserves empty transcription output for silence handling", async () => {
  const app = await createTestApp(new FakeProvider("Hello\\nworld", ""));
  const request = multipartBody(m4a, "audio/mp4", "audio", "recording.m4a");
  try {
    const response = await app.inject({
      method: "POST",
      url: "/transcriptions",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), {
      text: "",
      is_translated: false,
      request_id: String(response.headers["x-request-id"]),
    });
  } finally {
    await app.close();
  }
});

test("rejects non-empty encouragement input", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({
      method: "POST",
      url: "/encouragements",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      payload: JSON.stringify({ prompt: "anything" }),
    });
    assert.equal(response.statusCode, 400);
    assert.equal(response.json().error.code, "invalid_input");
  } finally {
    await app.close();
  }
});

test("rejects unsupported uploads", async () => {
  const app = await createTestApp();
  const request = multipartBody(Buffer.from("not an image"));
  try {
    const response = await app.inject({
      method: "POST",
      url: "/image-text",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 400);
    assert.equal(response.json().error.code, "unsupported_file");
  } finally {
    await app.close();
  }
});
