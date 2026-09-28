import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import Fastify, {
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
} from "fastify";
import multipart from "@fastify/multipart";
import {
  ApiError,
  ProviderAuthenticationError,
  ProviderFailureError,
  ProviderTimeoutError,
} from "./errors.js";
import {
  ComputerApprovalError,
  ComputerPolicyBlockedError,
  ComputerSessionNotFoundError,
} from "./computer-use.js";
import type { ComputerUseService } from "./computer-use-service.js";
import type { AppConfig } from "./config.js";
import { FixedWindowRateLimiter } from "./rate-limit.js";
import type {
  AudioMediaType,
  BackendProvider,
  ImageMediaType,
} from "./provider.js";
import type { TranscriptionWorkflow } from "./transcription.js";

const jpegHeader = Buffer.from([0xff, 0xd8, 0xff]);
const pngHeader = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const m4aContainerHeader = Buffer.from("ftyp");

export interface AppDependencies {
  config: AppConfig;
  provider: BackendProvider;
  transcriptionWorkflow: TranscriptionWorkflow;
  computerUse?: ComputerUseService;
}

class ClientDisconnectedError extends Error {
  constructor() {
    super("The client disconnected");
    this.name = "ClientDisconnectedError";
  }
}

function bearerToken(request: FastifyRequest): string | undefined {
  const value = request.headers.authorization;
  if (!value?.startsWith("Bearer ")) {
    return undefined;
  }
  const token = value.slice("Bearer ".length).trim();
  return token || undefined;
}

function tokenMatches(actual: string | undefined, expectedDigest: Buffer): boolean {
  if (!actual) {
    return false;
  }
  const actualDigest = createHash("sha256").update(actual).digest();
  return timingSafeEqual(actualDigest, expectedDigest);
}

function isJpeg(data: Buffer): boolean {
  return data.subarray(0, jpegHeader.length).equals(jpegHeader);
}

function isPng(data: Buffer): boolean {
  return data.subarray(0, pngHeader.length).equals(pngHeader);
}

function isM4A(data: Buffer): boolean {
  return data.subarray(4, 4 + m4aContainerHeader.length).equals(m4aContainerHeader);
}

function hasCode(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === code
  );
}

function toApiError(error: unknown): ApiError {
  if (error instanceof ApiError) {
    return error;
  }
  if (error instanceof ProviderTimeoutError) {
    return new ApiError(504, "provider_timeout", "The request timed out. Please try again.");
  }
  if (error instanceof ProviderAuthenticationError) {
    return new ApiError(502, "provider_authentication", "The provider is not configured correctly.");
  }
  if (error instanceof ProviderFailureError) {
    return new ApiError(502, "provider_failure", "The provider could not process the request. Please try again.");
  }
  if (error instanceof ComputerSessionNotFoundError) {
    return new ApiError(404, "computer_session_not_found", error.message);
  }
  if (error instanceof ComputerApprovalError) {
    return new ApiError(409, "computer_approval_required", error.message);
  }
  if (error instanceof ComputerPolicyBlockedError) {
    return new ApiError(422, "computer_policy_blocked", error.message);
  }
  if (hasCode(error, "FST_ERR_CTP_BODY_TOO_LARGE") || hasCode(error, "FST_REQ_FILE_TOO_LARGE")) {
    return new ApiError(413, "file_too_large", "The uploaded file is too large.");
  }
  if (hasCode(error, "FST_ERR_CTP_INVALID_MEDIA_TYPE")) {
    return new ApiError(400, "invalid_input", "The request must be multipart form data.");
  }
  return new ApiError(500, "internal_error", "Something went wrong. Please try again.");
}

interface ImageUpload {
  data: Buffer;
  mediaType: ImageMediaType;
}

interface AudioUpload {
  data: Buffer;
  mediaType: AudioMediaType;
}

interface ComputerResultUpload {
  result: unknown;
  screenshot: Buffer;
  currentURL?: string;
  currentTitle?: string;
}

async function readImage(request: FastifyRequest, config: AppConfig): Promise<ImageUpload> {
  if (!request.isMultipart()) {
    throw new ApiError(400, "invalid_input", "The request must be multipart form data.");
  }

  let part;
  try {
    part = await request.file();
  } catch (error) {
    throw toApiError(error);
  }

  if (!part) {
    throw new ApiError(400, "invalid_input", "The image field is required.");
  }
  if (part.fieldname !== "image") {
    throw new ApiError(400, "invalid_input", "The image field is required.");
  }
  if (part.mimetype !== "image/jpeg" && part.mimetype !== "image/png") {
    throw new ApiError(400, "unsupported_file", "Only JPEG and PNG images are supported.");
  }
  const mediaType = part.mimetype as ImageMediaType;

  const chunks: Buffer[] = [];
  let size = 0;
  try {
    for await (const chunk of part.file) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > config.imageMaxBytes) {
        throw new ApiError(413, "file_too_large", "The image is too large.");
      }
      chunks.push(buffer);
    }
  } catch (error) {
    if (error instanceof ApiError) {
      throw error;
    }
    throw toApiError(error);
  }

  if (part.file.truncated) {
    throw new ApiError(413, "file_too_large", "The image is too large.");
  }

  const image = Buffer.concat(chunks);
  if (image.length === 0) {
    throw new ApiError(400, "invalid_input", "The image field is required.");
  }
  const validImage = mediaType === "image/jpeg" ? isJpeg(image) : isPng(image);
  if (!validImage) {
    throw new ApiError(400, "unsupported_file", "The uploaded file is not a valid JPEG or PNG.");
  }
  return { data: image, mediaType };
}

async function readAudio(request: FastifyRequest, config: AppConfig): Promise<AudioUpload> {
  if (!request.isMultipart()) {
    throw new ApiError(400, "invalid_input", "The request must be multipart form data.");
  }

  let part;
  try {
    part = await request.file();
  } catch (error) {
    throw toApiError(error);
  }

  if (!part) {
    throw new ApiError(400, "invalid_input", "The audio field is required.");
  }
  if (part.fieldname !== "audio") {
    throw new ApiError(400, "invalid_input", "The audio field is required.");
  }
  const supportedTypes: AudioMediaType[] = ["audio/mp4", "audio/m4a", "audio/x-m4a"];
  if (!supportedTypes.includes(part.mimetype as AudioMediaType)) {
    throw new ApiError(400, "unsupported_file", "Only M4A audio is supported.");
  }
  const mediaType = part.mimetype as AudioMediaType;

  const chunks: Buffer[] = [];
  let size = 0;
  try {
    for await (const chunk of part.file) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > config.audioMaxBytes) {
        throw new ApiError(413, "file_too_large", "The audio file is too large.");
      }
      chunks.push(buffer);
    }
  } catch (error) {
    if (error instanceof ApiError) {
      throw error;
    }
    throw toApiError(error);
  }

  if (part.file.truncated) {
    throw new ApiError(413, "file_too_large", "The audio file is too large.");
  }

  const audio = Buffer.concat(chunks);
  if (audio.length === 0) {
    throw new ApiError(400, "invalid_input", "The audio field is required.");
  }
  if (!isM4A(audio)) {
    throw new ApiError(400, "unsupported_file", "The uploaded file is not a valid M4A recording.");
  }
  return { data: audio, mediaType };
}

async function readComputerResult(
  request: FastifyRequest,
  config: AppConfig,
): Promise<ComputerResultUpload> {
  if (!request.isMultipart()) {
    throw new ApiError(400, "invalid_input", "The request must be multipart form data.");
  }
  let resultText: string | undefined;
  let currentURL: string | undefined;
  let currentTitle: string | undefined;
  let screenshot: Buffer | undefined;
  try {
    for await (const part of request.parts()) {
      if (part.type === "file") {
        if (part.fieldname !== "screenshot" || screenshot) {
          throw new ApiError(400, "invalid_input", "Exactly one screenshot file is required.");
        }
        if (part.mimetype !== "image/png") {
          throw new ApiError(400, "unsupported_file", "The screenshot must be a PNG image.");
        }
        const chunks: Buffer[] = [];
        let size = 0;
        for await (const chunk of part.file) {
          const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          size += buffer.length;
          if (size > Math.min(config.computerUseMaxScreenshotBytes, 4 * 1024 * 1024)) {
            throw new ApiError(413, "file_too_large", "The screenshot is too large.");
          }
          chunks.push(buffer);
        }
        if (part.file.truncated) {
          throw new ApiError(413, "file_too_large", "The screenshot is too large.");
        }
        screenshot = Buffer.concat(chunks);
      } else if (part.fieldname === "result") {
        if (resultText !== undefined) {
          throw new ApiError(400, "invalid_input", "The result field may only be sent once.");
        }
        if (typeof part.value === "string") {
          resultText = part.value;
        } else {
          try {
            resultText = JSON.stringify(part.value);
          } catch {
            throw new ApiError(400, "invalid_input", "The result field must contain valid JSON.");
          }
        }
      } else if (part.fieldname === "current_url") {
        if (typeof part.value !== "string") {
          throw new ApiError(400, "invalid_input", "current_url must be text.");
        }
        currentURL = part.value;
      } else if (part.fieldname === "current_title") {
        if (typeof part.value !== "string") {
          throw new ApiError(400, "invalid_input", "current_title must be text.");
        }
        currentTitle = part.value;
      } else {
        throw new ApiError(400, "invalid_input", "The request contains an unknown field.");
      }
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw toApiError(error);
  }
  if (!screenshot || screenshot.length === 0 || !isPng(screenshot)) {
    throw new ApiError(400, "unsupported_file", "The uploaded screenshot is not a valid PNG.");
  }
  if (resultText === undefined || Buffer.byteLength(resultText, "utf8") > 4 * 1024 * 1024) {
    throw new ApiError(400, "invalid_input", "The result field is required and must be bounded.");
  }
  let result: unknown;
  try {
    result = JSON.parse(resultText);
  } catch {
    throw new ApiError(400, "invalid_input", "The result field must contain valid JSON.");
  }
  return { result, screenshot, currentURL, currentTitle };
}

function computerSessionPayload(response: Awaited<ReturnType<ComputerUseService["start"]>>): Record<string, unknown> {
  const step = response.step;
  return {
    session_id: response.session.id,
    status: response.session.status,
    done: response.done ?? false,
    message: response.message,
    step: step
      ? {
          id: step.id,
          code: step.code,
          code_hash: step.codeHash,
          browser_state_hash: step.browserStateHash,
          summary: step.summary,
          risk: step.risk,
          status: step.status,
          approval_expires_at: step.approvalExpiresAt,
        }
      : undefined,
    guardrail_reasons: response.guardrailReasons,
  };
}

async function runWithDeadline<T>(
  request: FastifyRequest,
  operation: (signal: AbortSignal) => Promise<T>,
  config: AppConfig,
  providerTimeoutMs = config.providerTimeoutMs,
  overallTimeoutMs = config.overallTimeoutMs,
): Promise<T | undefined> {
  const controller = new AbortController();
  let timedOut = false;
  let clientDisconnected = false;
  const timeoutMs = Math.min(providerTimeoutMs, overallTimeoutMs);
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const onAborted = () => {
    clientDisconnected = true;
    controller.abort();
  };
  request.raw.once("aborted", onAborted);

  const timeoutPromise = new Promise<never>((_, reject) => {
    const timer = setTimeout(() => reject(new ProviderTimeoutError()), timeoutMs);
    controller.signal.addEventListener("abort", () => clearTimeout(timer), { once: true });
  });
  const disconnectPromise = new Promise<never>((_, reject) => {
    request.raw.once("aborted", () => reject(new ClientDisconnectedError()));
  });

  try {
    return await Promise.race([
      operation(controller.signal),
      timeoutPromise,
      disconnectPromise,
    ]);
  } catch (error) {
    if (clientDisconnected || error instanceof ClientDisconnectedError) {
      return undefined;
    }
    if (timedOut || error instanceof ProviderTimeoutError) {
      throw new ProviderTimeoutError();
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    request.raw.removeListener("aborted", onAborted);
  }
}

export async function buildApp({
  config,
  provider,
  transcriptionWorkflow,
  computerUse,
}: AppDependencies): Promise<FastifyInstance> {
  const expectedTokenDigest = createHash("sha256").update(config.serviceToken).digest();
  const rateLimiter = new FixedWindowRateLimiter(
    config.rateLimitMax,
    config.rateLimitWindowMs,
  );

  const app = Fastify({
    bodyLimit: config.requestBodyMaxBytes,
    genReqId: () => randomUUID(),
    logger: true,
  });

  await app.register(multipart, {
    limits: {
      fields: 4,
      files: 1,
      fileSize: config.requestBodyMaxBytes,
      parts: 5,
    },
  });

  app.addHook("onRequest", async (request, reply) => {
    reply.header("X-Request-ID", request.id);

    if (request.url.split("?", 1)[0] === "/status") {
      return;
    }
    if (!tokenMatches(bearerToken(request), expectedTokenDigest)) {
      throw new ApiError(401, "authentication_failed", "Authentication required.");
    }
    if (
      request.method === "POST" &&
      (["/image-text", "/encouragements", "/transcriptions"].includes(
        request.url.split("?", 1)[0],
      ) || request.url.split("?", 1)[0].startsWith("/computer-use/"))
    ) {
      if (!rateLimiter.allow()) {
        const retryAfterSeconds = rateLimiter.retryAfterSeconds();
        throw new ApiError(
          429,
          "rate_limited",
          "Too many requests. Please try again later.",
          retryAfterSeconds,
        );
      }
    }
  });

  app.get("/status", async () => ({
    status: "ok",
    providers: {
      openai: { configured: Boolean(config.openAIAPIKey) },
      typesafe: { configured: Boolean(config.typesafeAPIKey) },
      computer_use: {
        configured: Boolean(config.openAIAPIKey && config.typesafeAPIKey),
        model: config.computerUseModel,
      },
    },
  }));

  app.post("/image-text", async (request, reply) => {
    const image = await readImage(request, config);
    const text = await runWithDeadline(
      request,
      (signal) => provider.extractText(image.data, image.mediaType, signal),
      config,
    );
    if (text === undefined || reply.raw.destroyed) {
      return;
    }
    return { text, request_id: request.id };
  });

  app.post("/encouragements", async (request, reply) => {
    const body = request.body;
    if (
      typeof body !== "object" ||
      body === null ||
      Array.isArray(body) ||
      Object.keys(body).length !== 0
    ) {
      throw new ApiError(400, "invalid_input", "The request body must be an empty JSON object.");
    }

    const text = await runWithDeadline(
      request,
      (signal) => provider.generateEncouragement(signal),
      config,
    );
    if (text === undefined || reply.raw.destroyed) {
      return;
    }
    return { text, request_id: request.id };
  });

  app.post("/transcriptions", async (request, reply) => {
    const audio = await readAudio(request, config);
    const result = await runWithDeadline(
      request,
      (signal) =>
        transcriptionWorkflow.transcribeAudio(audio.data, audio.mediaType, signal),
      config,
      config.transcriptionOverallTimeoutMs,
      config.transcriptionOverallTimeoutMs,
    );
    if (result === undefined || reply.raw.destroyed) {
      return;
    }

    if (result.languageJudgment) {
      request.log.info(
        {
          requestId: request.id,
          provider: "typesafe",
          model: result.languageJudgment.model,
          question: "majority_english",
          noul: result.languageJudgment.probability,
          branch: result.branch,
          usage: result.languageJudgment.usage,
        },
        "typesafe_judgment",
      );
    }
    if (result.fallbackReason) {
      request.log.warn(
        {
          requestId: request.id,
          branch: result.branch,
          reason: result.fallbackReason,
        },
        "typesafe_fallback",
      );
    }

    return {
      text: result.text,
      is_translated: result.isTranslated,
      request_id: request.id,
    };
  });

  app.post("/computer-use/sessions", async (request, reply) => {
    if (!computerUse) {
      throw new ProviderFailureError();
    }
    const body = request.body;
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
      throw new ApiError(400, "invalid_input", "The request body must be a JSON object.");
    }
    const value = body as Record<string, unknown>;
    const instruction = value.instruction;
    const initialURL = value.initial_url;
    const allowedOrigins = value.allowed_origins;
    const currentURL = value.current_url;
    const currentTitle = value.current_title;
    if (
      typeof instruction !== "string" ||
      typeof initialURL !== "string" ||
      !Array.isArray(allowedOrigins) ||
      !allowedOrigins.every((origin) => typeof origin === "string") ||
      (currentURL !== undefined && typeof currentURL !== "string") ||
      (currentTitle !== undefined && typeof currentTitle !== "string")
    ) {
      throw new ApiError(400, "invalid_input", "instruction, initial_url, and allowed_origins are required.");
    }
    try {
      const url = new URL(initialURL);
      if (!["http:", "https:"].includes(url.protocol)) throw new Error();
      if (!allowedOrigins.includes(url.origin) || allowedOrigins.length > 20) throw new Error();
      for (const origin of allowedOrigins) {
        const parsedOrigin = new URL(origin);
        if (!["http:", "https:"].includes(parsedOrigin.protocol) || parsedOrigin.origin !== origin) throw new Error();
      }
    } catch {
      throw new ApiError(400, "invalid_input", "The initial URL and allowed origins must be valid HTTP origins.");
    }
    const result = await runWithDeadline(
      request,
      (signal) => computerUse.start({ instruction, initialURL, allowedOrigins, currentURL, currentTitle }, signal),
      config,
      config.computerUseOverallTimeoutMs,
      config.computerUseOverallTimeoutMs,
    );
    if (result === undefined || reply.raw.destroyed) return;
    return computerSessionPayload(result);
  });

  app.post("/computer-use/sessions/:sessionId/steps/:stepId/approve", async (request) => {
    if (!computerUse) throw new ProviderFailureError();
    const body = request.body;
    const codeHash =
      typeof body === "object" && body !== null && !Array.isArray(body)
        ? (body as Record<string, unknown>).code_hash
        : undefined;
    const browserStateHash =
      typeof body === "object" && body !== null && !Array.isArray(body)
        ? (body as Record<string, unknown>).browser_state_hash
        : undefined;
    if (typeof codeHash !== "string" || codeHash.length !== 64 || typeof browserStateHash !== "string" || browserStateHash.length !== 64) {
      throw new ApiError(400, "invalid_input", "code_hash and browser_state_hash are required.");
    }
    const params = request.params as { sessionId: string; stepId: string };
    const result = await runWithDeadline(
      request,
      async () => computerUse.approve(params.sessionId, params.stepId, codeHash, browserStateHash),
      config,
      config.computerUseOverallTimeoutMs,
      config.computerUseOverallTimeoutMs,
    );
    if (result === undefined) return;
    return computerSessionPayload(result);
  });

  app.post("/computer-use/sessions/:sessionId/steps/:stepId/deny", async (request) => {
    if (!computerUse) throw new ProviderFailureError();
    const params = request.params as { sessionId: string; stepId: string };
    const result = await runWithDeadline(
      request,
      async () => computerUse.deny(params.sessionId, params.stepId),
      config,
      config.computerUseOverallTimeoutMs,
      config.computerUseOverallTimeoutMs,
    );
    if (result === undefined) return;
    return computerSessionPayload(result);
  });

  app.post("/computer-use/sessions/:sessionId/steps/:stepId/result", async (request, reply) => {
    if (!computerUse) throw new ProviderFailureError();
    const upload = await readComputerResult(request, config);
    const params = request.params as { sessionId: string; stepId: string };
    const result = await runWithDeadline(
      request,
      (signal) =>
        computerUse.submitResult(
          {
            sessionId: params.sessionId,
            stepId: params.stepId,
            result: upload.result,
            screenshot: upload.screenshot,
            currentURL: upload.currentURL,
            currentTitle: upload.currentTitle,
          },
          signal,
        ),
      config,
      config.computerUseOverallTimeoutMs,
      config.computerUseOverallTimeoutMs,
    );
    if (result === undefined || reply.raw.destroyed) return;
    return computerSessionPayload(result);
  });

  app.delete("/computer-use/sessions/:sessionId", async (request) => {
    if (!computerUse) throw new ProviderFailureError();
    const params = request.params as { sessionId: string };
    const result = await runWithDeadline(
      request,
      async () => {
        await computerUse.cancel(params.sessionId);
        return { status: "cancelled" };
      },
      config,
      config.computerUseOverallTimeoutMs,
      config.computerUseOverallTimeoutMs,
    );
    if (result === undefined) return;
    return { ...result, session_id: params.sessionId };
  });

  app.setErrorHandler((error, request, reply) => {
    const apiError = toApiError(error);
    request.log.error(
      {
        requestId: request.id,
        code: apiError.code,
        statusCode: apiError.statusCode,
        errorName: error instanceof Error ? error.name : undefined,
        errorMessage: error instanceof Error ? error.message : String(error),
        errorStack: error instanceof Error ? error.stack : undefined,
      },
      "request_failed",
    );
    if (reply.sent || reply.raw.destroyed) {
      return;
    }
    if (apiError.retryAfterSeconds !== undefined) {
      reply.header("Retry-After", apiError.retryAfterSeconds);
    }
    reply.code(apiError.statusCode).send({
      error: {
        code: apiError.code,
        message: apiError.publicMessage,
      },
      request_id: request.id,
    });
  });

  return app;
}
