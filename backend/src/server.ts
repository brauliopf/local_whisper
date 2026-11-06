import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createOpenAIImageTextProvider } from "./provider.js";
import { TranscriptionWorkflow } from "./transcription.js";
import { createTypeSafeLanguageClassifier } from "./typesafe.js";
import { PostgresConversationStore } from "./memory.js";
import { EntityMemoryService } from "./entity-memory.js";

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
const conversationStore = config.conversationStoreURL && config.conversationStoreSecretKey
  ? new PostgresConversationStore(
      config.conversationStoreURL,
      config.conversationStoreSecretKey,
    )
  : undefined;
const entityMemory = conversationStore
  ? new EntityMemoryService(provider, conversationStore)
  : undefined;

const app = await buildApp({
  config,
  provider,
  transcriptionWorkflow,
  conversationStore,
  entityMemory,
});

if (!conversationStore) {
  app.log.fatal(
    { missing: ["SUPABASE_URL", "SUPABASE_SECRET_KEY"] },
    "supabase_configuration_missing",
  );
  await app.close();
  throw new Error("SUPABASE_URL and SUPABASE_SECRET_KEY are required to start the backend.");
}

try {
  await conversationStore.checkConnection();
  app.log.info(
    { tables: ["conversations", "messages"] },
    "supabase_startup_check_succeeded",
  );
} catch (error) {
  app.log.fatal({ err: error }, "supabase_startup_check_failed");
  await app.close();
  throw new Error("Supabase conversation tables are not available at startup.", { cause: error });
}

const close = async (signal: string) => {
  app.log.info({ signal }, "shutting_down");
  await app.close();
  process.exit(0);
};

process.once("SIGINT", () => void close("SIGINT"));
process.once("SIGTERM", () => void close("SIGTERM"));

await app.listen({ host: "0.0.0.0", port: config.port });
