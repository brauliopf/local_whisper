import assert from "node:assert/strict";
import { test } from "node:test";
import type { AppConfig } from "./config.js";
import { buildApp } from "./app.js";
import type { ImageTextProvider } from "./provider.js";

const serviceToken = "test-service-token";
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]);
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xd9]);

const config: AppConfig = {
  port: 8080,
  openAIAPIKey: "not-used-in-tests",
  serviceToken,
  imageTextModel: "gpt-4o-mini",
  imageMaxBytes: 10 * 1024 * 1024,
  requestBodyMaxBytes: 12 * 1024 * 1024,
  providerTimeoutMs: 100,
  overallTimeoutMs: 150,
  rateLimitMax: 10,
  rateLimitWindowMs: 60_000,
};

class FakeProvider implements ImageTextProvider {
  constructor(private readonly result: string | null = "Hello\\nworld") {}

  async extractText(): Promise<string | null> {
    return this.result;
  }
}

function multipartBody(image: Buffer, contentType = "image/jpeg") {
  const boundary = "test-boundary";
  const prefix = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="image"; filename="screenshot.jpg"\r\nContent-Type: ${contentType}\r\n\r\n`,
  );
  const suffix = Buffer.from(`\r\n--${boundary}--\r\n`);
  return {
    body: Buffer.concat([prefix, image, suffix]),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}

async function createTestApp(provider: ImageTextProvider = new FakeProvider()) {
  return buildApp({ config, provider });
}

test("status does not require authentication", async () => {
  const app = await createTestApp();
  try {
    const response = await app.inject({ method: "GET", url: "/status" });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), { status: "ok" });
    assert.match(String(response.headers["x-request-id"] ?? ""), /^[0-9a-f-]{36}$/);
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
