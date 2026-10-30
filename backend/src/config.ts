export interface AppConfig {
  port: number;
  openAIAPIKey: string;
  serviceToken: string;
  typesafeAPIKey: string;
  imageTextModel: string;
  encouragementModel: string;
  transcriptionModel: string;
  translationModel: string;
  typesafeModel: string;
  imageMaxBytes: number;
  audioMaxBytes: number;
  requestBodyMaxBytes: number;
  providerTimeoutMs: number;
  overallTimeoutMs: number;
  transcriptionProviderTimeoutMs: number;
  transcriptionOverallTimeoutMs: number;
  typesafeProviderTimeoutMs: number;
  translationProviderTimeoutMs: number;
  transcriptMaxChars: number;
  rateLimitMax: number;
  rateLimitWindowMs: number;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function positiveInteger(
  env: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
): number {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  return {
    port: positiveInteger(env, "PORT", 8080),
    openAIAPIKey: required(env, "OPENAI_API_KEY"),
    serviceToken: required(env, "SERVICE_TOKEN"),
    typesafeAPIKey: env.TYPESAFE_API_KEY?.trim() ?? "",
    imageTextModel: env.IMAGE_TEXT_MODEL?.trim() || "gpt-4o-mini",
    encouragementModel: env.ENCOURAGEMENT_MODEL?.trim() || "gpt-4o-mini",
    transcriptionModel: env.TRANSCRIPTION_MODEL?.trim() || "whisper-1",
    translationModel: env.TRANSLATION_MODEL?.trim() || "gpt-4o-mini",
    typesafeModel: env.TYPESAFE_MODEL?.trim() || "jev-1.13.0",
    imageMaxBytes: positiveInteger(env, "IMAGE_MAX_BYTES", 10 * 1024 * 1024),
    audioMaxBytes: positiveInteger(env, "AUDIO_MAX_BYTES", 25 * 1024 * 1024),
    requestBodyMaxBytes: positiveInteger(
      env,
      "REQUEST_BODY_MAX_BYTES",
      27 * 1024 * 1024,
    ),
    providerTimeoutMs: positiveInteger(env, "PROVIDER_TIMEOUT_MS", 60_000),
    overallTimeoutMs: positiveInteger(env, "OVERALL_TIMEOUT_MS", 75_000),
    transcriptionProviderTimeoutMs: positiveInteger(
      env,
      "TRANSCRIPTION_PROVIDER_TIMEOUT_MS",
      70_000,
    ),
    transcriptionOverallTimeoutMs: positiveInteger(
      env,
      "TRANSCRIPTION_OVERALL_TIMEOUT_MS",
      105_000,
    ),
    typesafeProviderTimeoutMs: positiveInteger(
      env,
      "TYPESAFE_PROVIDER_TIMEOUT_MS",
      5_000,
    ),
    translationProviderTimeoutMs: positiveInteger(
      env,
      "TRANSLATION_PROVIDER_TIMEOUT_MS",
      25_000,
    ),
    transcriptMaxChars: positiveInteger(env, "TRANSCRIPT_MAX_CHARS", 20_000),
    rateLimitMax: positiveInteger(env, "RATE_LIMIT_MAX", 10),
    rateLimitWindowMs: positiveInteger(env, "RATE_LIMIT_WINDOW_MS", 60_000),
  };
}
