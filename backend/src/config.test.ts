import assert from "node:assert/strict";
import { test } from "node:test";
import { loadConfig } from "./config.js";

test("loads translation and TypeSafe configuration with backend defaults", () => {
  const config = loadConfig({
    OPENAI_API_KEY: " openai-key ",
    SERVICE_TOKEN: " service-token ",
    TYPESAFE_API_KEY: "   ",
  });

  assert.equal(config.openAIAPIKey, "openai-key");
  assert.equal(config.serviceToken, "service-token");
  assert.equal(config.typesafeAPIKey, "");
  assert.equal(config.typesafeModel, "jev-1.13.0");
  assert.equal(config.translationModel, "gpt-4o-mini");
  assert.equal(config.transcriptionProviderTimeoutMs, 70_000);
  assert.equal(config.transcriptionOverallTimeoutMs, 105_000);
  assert.equal(config.typesafeProviderTimeoutMs, 5_000);
  assert.equal(config.translationProviderTimeoutMs, 25_000);
  assert.equal(config.transcriptMaxChars, 20_000);
});
