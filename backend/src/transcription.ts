import {
  ProviderAuthenticationError,
  ProviderFailureError,
  ProviderTimeoutError,
} from "./errors.js";
import type {
  AudioMediaType,
  TranscriptionProvider,
  TranslationProvider,
} from "./provider.js";
import type { LanguageClassifier, LanguageJudgment } from "./typesafe.js";

export type TranscriptionBranch = "original" | "translate" | "translate_fallback";
export type TypeSafeFallbackReason =
  | "typesafe_unconfigured"
  | "typesafe_timeout"
  | "typesafe_authentication"
  | "typesafe_failure";

export interface TranscriptionResult {
  text: string;
  isTranslated: boolean;
  branch: TranscriptionBranch;
  languageJudgment?: LanguageJudgment;
  fallbackReason?: TypeSafeFallbackReason;
}

export interface TranscriptionWorkflowOptions {
  transcriber: TranscriptionProvider;
  translator: TranslationProvider;
  classifier?: LanguageClassifier;
  transcriptionTimeoutMs: number;
  typesafeTimeoutMs: number;
  translationTimeoutMs: number;
  maxTranscriptChars: number;
}

const runStep = async <T>(
  signal: AbortSignal,
  timeoutMs: number,
  operation: (stepSignal: AbortSignal) => Promise<T>,
): Promise<T> => {
  const controller = new AbortController();
  let timedOut = false;
  const onAbort = () => controller.abort();
  signal.addEventListener("abort", onAbort, { once: true });
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  let timeoutRejectTimer: ReturnType<typeof setTimeout> | undefined;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutRejectTimer = setTimeout(
      () => reject(new ProviderTimeoutError()),
      timeoutMs,
    );
  });

  try {
    return await Promise.race([operation(controller.signal), timeoutPromise]);
  } catch (error) {
    if (signal.aborted) {
      throw error;
    }
    if (timedOut) {
      throw new ProviderTimeoutError();
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    if (timeoutRejectTimer) {
      clearTimeout(timeoutRejectTimer);
    }
    signal.removeEventListener("abort", onAbort);
  }
}

const fallbackReason = (error: unknown): TypeSafeFallbackReason => {
  if (error instanceof ProviderTimeoutError) {
    return "typesafe_timeout";
  }
  if (error instanceof ProviderAuthenticationError) {
    return "typesafe_authentication";
  }
  return "typesafe_failure";
};

export class TranscriptionWorkflow {
  constructor(private readonly options: TranscriptionWorkflowOptions) {}

  async transcribeAudio(
    audio: Buffer,
    mediaType: AudioMediaType,
    signal: AbortSignal,
  ): Promise<TranscriptionResult> {
    const rawTranscript = await runStep(
      signal,
      this.options.transcriptionTimeoutMs,
      (stepSignal) => this.options.transcriber.transcribeAudio(audio, mediaType, stepSignal),
    );
    const transcript = rawTranscript.trim();

    if (!transcript) {
      return {
        text: "",
        isTranslated: false,
        branch: "original",
      };
    }
    if (transcript.length > this.options.maxTranscriptChars) {
      throw new ProviderFailureError();
    }

    let shouldTranslate = true;
    let branch: TranscriptionBranch = "translate_fallback";
    let languageJudgment: LanguageJudgment | undefined;
    let fallback: TypeSafeFallbackReason | undefined;

    if (this.options.classifier) {
      try {
        languageJudgment = await runStep(
          signal,
          this.options.typesafeTimeoutMs,
          (stepSignal) => this.options.classifier!.judgeMajorityEnglish(transcript, stepSignal),
        );
        shouldTranslate = languageJudgment.probability < 0.5;
        branch = shouldTranslate ? "translate" : "original";
      } catch (error) {
        if (signal.aborted) {
          throw error;
        }
        fallback = fallbackReason(error);
      }
    } else {
      fallback = "typesafe_unconfigured";
    }

    if (!shouldTranslate) {
      return {
        text: transcript,
        isTranslated: false,
        branch,
        languageJudgment,
      };
    }

    const rawTranslation = await runStep(
      signal,
      this.options.translationTimeoutMs,
      (stepSignal) => this.options.translator.translateToEnglish(transcript, stepSignal),
    );
    const translation = rawTranslation.trim();
    if (!translation) {
      throw new ProviderFailureError();
    }

    return {
      text: translation,
      isTranslated: true,
      branch,
      languageJudgment,
      fallbackReason: fallback,
    };
  }
}
