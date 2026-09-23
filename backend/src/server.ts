import OpenAI from "openai";
import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createOpenAIImageTextProvider } from "./provider.js";
import { TranscriptionWorkflow } from "./transcription.js";
import { createTypeSafeLanguageClassifier } from "./typesafe.js";

const config = loadConfig();
const provider = createOpenAIImageTextProvider(
  config.openAIAPIKey,
  config.imageTextModel,
  config.encouragementModel,
  config.transcriptionModel,
  config.translationModel,
  config.providerTimeoutMs,
);
const transcriptionWorkflow = new TranscriptionWorkflow({
  transcriber: provider,
  translator: provider,
  classifier: config.typesafeAPIKey
    ? createTypeSafeLanguageClassifier(config.typesafeAPIKey, config.typesafeModel)
    : undefined,
  transcriptionTimeoutMs: config.transcriptionProviderTimeoutMs,
  typesafeTimeoutMs: config.typesafeProviderTimeoutMs,
  translationTimeoutMs: config.translationProviderTimeoutMs,
  maxTranscriptChars: config.transcriptMaxChars,
});
const app = await buildApp({
  config,
  provider,
  transcriptionWorkflow,
});

const close = async (signal: string) => {
  app.log.info({ signal }, "shutting_down");
  await app.close();
  process.exit(0);
};

process.once("SIGINT", () => void close("SIGINT"));
process.once("SIGTERM", () => void close("SIGTERM"));

await app.listen({ host: "0.0.0.0", port: config.port });
