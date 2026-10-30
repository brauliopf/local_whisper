import OpenAI, { toFile } from "openai";
import {
  ProviderAuthenticationError,
  ProviderFailureError,
  ProviderTimeoutError,
} from "./errors.js";
import {
  encouragementInput,
  encouragementPrompt,
  imageTextPrompt,
  translationPrompt,
} from "./prompts.js";

export type ImageMediaType = "image/jpeg" | "image/png";
export type AudioMediaType = "audio/mp4" | "audio/m4a" | "audio/x-m4a";

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

export class OpenAIImageTextProvider implements BackendProvider {
  constructor(
    private readonly client: OpenAI,
    private readonly imageTextModel: string,
    private readonly encouragementModel: string,
    private readonly transcriptionModel: string,
    private readonly translationModel: string,
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
  timeoutMs: number,
): OpenAIImageTextProvider {
  return new OpenAIImageTextProvider(
    new OpenAI({ apiKey, timeout: timeoutMs, maxRetries: 0 }),
    imageTextModel,
    encouragementModel,
    transcriptionModel,
    translationModel,
  );
}
