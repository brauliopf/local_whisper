import OpenAI from "openai";
import { Firestore } from "@google-cloud/firestore";
import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createOpenAIImageTextProvider } from "./provider.js";
import { TranscriptionWorkflow } from "./transcription.js";
import { createTypeSafeLanguageClassifier } from "./typesafe.js";
import {
  FirestoreComputerSessionRepository,
  OpenAIComputerPlanner,
  TypeSafeComputerGuardrail,
} from "./computer-use.js";
import { ComputerUseService } from "./computer-use-service.js";
import { ProviderFailureError } from "./errors.js";

const config = loadConfig();
const provider = createOpenAIImageTextProvider(
  config.openAIAPIKey,
  config.imageTextModel,
  config.encouragementModel,
  config.transcriptionModel,
  config.translationModel,
  config.providerTimeoutMs,
);
const classifier = config.typesafeAPIKey
  ? createTypeSafeLanguageClassifier(config.typesafeAPIKey, config.typesafeModel)
  : undefined;
const transcriptionWorkflow = new TranscriptionWorkflow({
  transcriber: provider,
  translator: provider,
  classifier,
  transcriptionTimeoutMs: config.transcriptionProviderTimeoutMs,
  typesafeTimeoutMs: config.typesafeProviderTimeoutMs,
  translationTimeoutMs: config.translationProviderTimeoutMs,
  maxTranscriptChars: config.transcriptMaxChars,
});
const openAI = new OpenAI({ apiKey: config.openAIAPIKey });
const computerGuardrail = classifier
  ? new TypeSafeComputerGuardrail(classifier)
  : {
      evaluate: async () => {
        throw new ProviderFailureError();
      },
    };
const computerUse = new ComputerUseService({
  repository: new FirestoreComputerSessionRepository(
    new Firestore({ ignoreUndefinedProperties: true }),
  ),
  planner: new OpenAIComputerPlanner(openAI, config.computerUseModel),
  guardrail: computerGuardrail,
  maxIterations: Math.min(config.computerUseMaxIterations, 20),
  maxTaskDurationMs: Math.min(config.computerUseTaskDurationMs, 10 * 60 * 1000),
  maxRegenerationsPerStep: Math.min(config.computerUseMaxRegenerations, 3),
  maxScreenshotBytes: Math.min(config.computerUseMaxScreenshotBytes, 4 * 1024 * 1024),
  approvalTimeoutMs: Math.min(config.computerUseApprovalTimeoutMs, 10 * 60 * 1000),
});
const app = await buildApp({
  config,
  provider,
  transcriptionWorkflow,
  computerUse,
});

const close = async (signal: string) => {
  app.log.info({ signal }, "shutting_down");
  await app.close();
  process.exit(0);
};

process.once("SIGINT", () => void close("SIGINT"));
process.once("SIGTERM", () => void close("SIGTERM"));

await app.listen({ host: "0.0.0.0", port: config.port });
