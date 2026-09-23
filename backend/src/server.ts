import OpenAI from "openai";
import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createOpenAIImageTextProvider } from "./provider.js";

const config = loadConfig();
const app = await buildApp({
  config,
  provider: createOpenAIImageTextProvider(
    config.openAIAPIKey,
    config.imageTextModel,
    config.providerTimeoutMs,
  ),
});

const close = async (signal: string) => {
  app.log.info({ signal }, "shutting_down");
  await app.close();
  process.exit(0);
};

process.once("SIGINT", () => void close("SIGINT"));
process.once("SIGTERM", () => void close("SIGTERM"));

await app.listen({ host: "0.0.0.0", port: config.port });
