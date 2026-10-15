import OpenAI, { toFile } from "openai";
import {
  ProviderAuthenticationError,
  ProviderFailureError,
  ProviderTimeoutError,
} from "./errors.js";
import {
  browserPlannerPrompt,
  encouragementInput,
  encouragementPrompt,
  imageTextPrompt,
  translationPrompt,
} from "./prompts.js";

export type ImageMediaType = "image/jpeg" | "image/png";
export type AudioMediaType = "audio/mp4" | "audio/m4a" | "audio/x-m4a";

export interface BrowserPlanRequest {
  goal: string;
  pageState: Record<string, unknown>;
  capabilityPolicy: Record<string, unknown>;
  policyVersion: string;
  sessionID: string;
}

export interface BrowserPlan {
  code: string;
  planID: string;
  policyVersion: string;
  stateHash: string;
  expiresAt: string;
}

export interface BrowserPlanner {
  generateBrowserPlan(
    request: BrowserPlanRequest,
    signal: AbortSignal,
  ): Promise<BrowserPlan>;
}

export interface ImageTextProvider {
  extractText(
    image: Buffer,
    mediaType: ImageMediaType,
    signal: AbortSignal,
  ): Promise<string | null>;
}

export interface EncouragementProvider {
  generateEncouragement(signal: AbortSignal): Promise<string>;
}

export interface TranscriptionProvider {
  transcribeAudio(
    audio: Buffer,
    mediaType: AudioMediaType,
    signal: AbortSignal,
  ): Promise<string>;
}

export interface TranslationProvider {
  translateToEnglish(text: string, signal: AbortSignal): Promise<string>;
}

export type BackendProvider =
  ImageTextProvider &
  EncouragementProvider &
  TranscriptionProvider &
  TranslationProvider;

function errorName(error: unknown): string | undefined {
  return error instanceof Error ? error.name : undefined;
}

function errorStatus(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("status" in error)) {
    return undefined;
  }
  const status = error.status;
  return typeof status === "number" ? status : undefined;
}

function normalizeProviderError(error: unknown): never {
  const name = errorName(error);
  if (name === "AbortError" || name === "APIConnectionTimeoutError") {
    throw new ProviderTimeoutError();
  }
  if (errorStatus(error) === 401) {
    throw new ProviderAuthenticationError();
  }
  throw new ProviderFailureError();
}

function wordCount(text: string): number {
  return text.split(/\s+/).filter(Boolean).length;
}

export class OpenAIImageTextProvider implements BackendProvider, BrowserPlanner {
  constructor(
    private readonly client: OpenAI,
    private readonly imageTextModel: string,
    private readonly encouragementModel: string,
    private readonly transcriptionModel: string,
    private readonly translationModel: string,
    private readonly browserPlannerModel: string,
  ) {}

  async extractText(
    image: Buffer,
    mediaType: ImageMediaType,
    signal: AbortSignal,
  ): Promise<string | null> {
    const imageURL = `data:${mediaType};base64,${image.toString("base64")}`;

    let response: OpenAI.Responses.Response;
    try {
      response = await this.client.responses.create(
        {
          model: this.imageTextModel,
          input: [
            {
              role: "user",
              content: [
                { type: "input_text", text: imageTextPrompt },
                { type: "input_image", image_url: imageURL, detail: "auto" },
              ],
            },
          ],
        },
        { signal },
      );
    } catch (error) {
      normalizeProviderError(error);
    }

    const text = response.output_text?.trim() ?? "";
    if (!text || text.toUpperCase() === "NO_TEXT") {
      return null;
    }
    return text;
  }

  async generateEncouragement(signal: AbortSignal): Promise<string> {
    let response: OpenAI.Responses.Response;
    try {
      response = await this.client.responses.create(
        {
          model: this.encouragementModel,
          instructions: encouragementPrompt,
          input: encouragementInput,
        },
        { signal },
      );
    } catch (error) {
      normalizeProviderError(error);
    }

    const text = response.output_text?.trim() ?? "";
    if (!text || wordCount(text) > 15) {
      throw new ProviderFailureError();
    }
    return text;
  }

  async transcribeAudio(
    audio: Buffer,
    mediaType: AudioMediaType,
    signal: AbortSignal,
  ): Promise<string> {
    let response: OpenAI.Audio.Transcription;
    try {
      const file = await toFile(audio, "recording.m4a", { type: mediaType });
      response = await this.client.audio.transcriptions.create(
        {
          file,
          model: this.transcriptionModel,
          response_format: "json",
        },
        { signal },
      );
    } catch (error) {
      normalizeProviderError(error);
    }

    return response.text.trim();
  }

  async generateBrowserPlan(
    request: BrowserPlanRequest,
    signal: AbortSignal,
  ): Promise<BrowserPlan> {
    let response: OpenAI.Responses.Response;
    try {
      response = await this.client.responses.create(
        {
          model: this.browserPlannerModel,
          instructions: browserPlannerPrompt,
          input: JSON.stringify(request),
          text: {
            format: {
              type: "json_schema",
              name: "browser_plan",
              strict: true,
              schema: {
                type: "object",
                additionalProperties: false,
                properties: {
                  code: { type: "string" },
                  plan_id: { type: "string" },
                  policy_version: { type: "string" },
                  state_hash: { type: "string" },
                  expires_at: { type: "string" },
                },
                required: ["code", "plan_id", "policy_version", "state_hash", "expires_at"],
              },
            },
          },
        },
        { signal },
      );
    } catch (error) {
      normalizeProviderError(error);
    }

    try {
      const value: unknown = JSON.parse(response.output_text ?? "");
      if (
        typeof value !== "object" ||
        value === null ||
        Array.isArray(value) ||
        typeof (value as Record<string, unknown>).code !== "string" ||
        typeof (value as Record<string, unknown>).plan_id !== "string" ||
        typeof (value as Record<string, unknown>).policy_version !== "string" ||
        typeof (value as Record<string, unknown>).state_hash !== "string" ||
        typeof (value as Record<string, unknown>).expires_at !== "string"
      ) {
        throw new Error("invalid browser plan");
      }
      const plan = value as Record<string, string>;
      return {
        code: plan.code,
        planID: plan.plan_id,
        policyVersion: plan.policy_version,
        stateHash: plan.state_hash,
        // The model cannot reliably provide wall-clock timestamps; bind plan lifetime server-side.
        expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
      };
    } catch {
      throw new ProviderFailureError();
    }
  }

  async translateToEnglish(text: string, signal: AbortSignal): Promise<string> {
    let response: OpenAI.Responses.Response;
    try {
      response = await this.client.responses.create(
        {
          model: this.translationModel,
          instructions: translationPrompt,
          input: text,
        },
        { signal },
      );
    } catch (error) {
      normalizeProviderError(error);
    }

    const translation = response.output_text?.trim() ?? "";
    if (!translation) {
      throw new ProviderFailureError();
    }
    return translation;
  }
}

export function createOpenAIImageTextProvider(
  apiKey: string,
  imageTextModel: string,
  encouragementModel: string,
  transcriptionModel: string,
  translationModel: string,
  browserPlannerModel: string,
  timeoutMs: number,
): OpenAIImageTextProvider {
  return new OpenAIImageTextProvider(
    new OpenAI({ apiKey, timeout: timeoutMs, maxRetries: 0 }),
    imageTextModel,
    encouragementModel,
    transcriptionModel,
    translationModel,
    browserPlannerModel,
  );
}
