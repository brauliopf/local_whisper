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
import type { AppConfig } from "./config.js";
import { FixedWindowRateLimiter } from "./rate-limit.js";
import type { BackendProvider, ImageMediaType } from "./provider.js";

const jpegHeader = Buffer.from([0xff, 0xd8, 0xff]);
const pngHeader = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export interface AppDependencies {
  config: AppConfig;
  provider: BackendProvider;
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
    return new ApiError(502, "provider_failure", "The image could not be processed. Please try again.");
  }
  if (hasCode(error, "FST_ERR_CTP_BODY_TOO_LARGE") || hasCode(error, "FST_REQ_FILE_TOO_LARGE")) {
    return new ApiError(413, "file_too_large", "The image is too large.");
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

async function runWithDeadline<T>(
  request: FastifyRequest,
  operation: (signal: AbortSignal) => Promise<T>,
  config: AppConfig,
): Promise<T | undefined> {
  const controller = new AbortController();
  let timedOut = false;
  let clientDisconnected = false;
  const timeoutMs = Math.min(config.providerTimeoutMs, config.overallTimeoutMs);
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

export async function buildApp({ config, provider }: AppDependencies): Promise<FastifyInstance> {
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
      fields: 0,
      files: 1,
      fileSize: config.imageMaxBytes,
      parts: 1,
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
      ["/image-text", "/encouragements"].includes(request.url.split("?", 1)[0])
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

  app.get("/status", async () => ({ status: "ok" }));

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

  app.setErrorHandler((error, request, reply) => {
    const apiError = toApiError(error);
    request.log.error(
      { requestId: request.id, code: apiError.code, statusCode: apiError.statusCode },
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
