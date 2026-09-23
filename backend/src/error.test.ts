import assert from "node:assert/strict";
import { test } from "node:test";
import type { AppConfig } from "./config.js";
import { buildApp } from "./app.js";
import { ProviderFailureError } from "./errors.js";
import type { BackendProvider } from "./provider.js";

const config: AppConfig = {
  port: 8080,
  openAIAPIKey: "not-used-in-tests",
  serviceToken: "test-service-token",
  imageTextModel: "gpt-4o-mini",
  encouragementModel: "gpt-4o-mini",
  transcriptionModel: "whisper-1",
  imageMaxBytes: 10 * 1024 * 1024,
  audioMaxBytes: 25 * 1024 * 1024,
  requestBodyMaxBytes: 27 * 1024 * 1024,
  providerTimeoutMs: 100,
  overallTimeoutMs: 150,
  transcriptionProviderTimeoutMs: 120,
  transcriptionOverallTimeoutMs: 150,
  rateLimitMax: 10,
  rateLimitWindowMs: 60_000,
};

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9]);

class FailingProvider implements BackendProvider {
  async extractText(): Promise<string | null> {
    throw new ProviderFailureError();
  }

  async generateEncouragement(): Promise<string> {
    throw new ProviderFailureError();
  }

  async transcribeAudio(): Promise<string> {
    throw new ProviderFailureError();
  }
}

function multipartBody() {
  const boundary = "error-boundary";
  const body = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="image"; filename="image.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`,
    ),
    jpeg,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  return { body, contentType: `multipart/form-data; boundary=${boundary}` };
}

test("normalizes provider failures", async () => {
  const app = await buildApp({ config, provider: new FailingProvider() });
  const request = multipartBody();
  try {
    const response = await app.inject({
      method: "POST",
      url: "/image-text",
      headers: {
        authorization: `Bearer ${config.serviceToken}`,
        "content-type": request.contentType,
      },
      payload: request.body,
    });
    assert.equal(response.statusCode, 502);
    assert.deepEqual(response.json().error, {
      code: "provider_failure",
      message: "The provider could not process the request. Please try again.",
    });
  } finally {
    await app.close();
  }
});
