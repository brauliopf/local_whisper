import assert from "node:assert/strict";
import { test } from "node:test";
import type { AppConfig } from "./config.js";
import { buildApp } from "./app.js";
import type { BackendProvider } from "./provider.js";
import { TranscriptionWorkflow } from "./transcription.js";

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

class FakeProvider implements BackendProvider {
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

async function createTestApp(provider: BackendProvider = new FakeProvider()) {
  return buildApp({
    config,
    provider,
    transcriptionWorkflow: createTranscriptionWorkflow(provider),
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
