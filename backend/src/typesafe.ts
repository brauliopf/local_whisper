import {
  ProviderAuthenticationError,
  ProviderFailureError,
} from "./errors.js";

const typeSafeEndpoint = "https://api.typesafe.ai/v1/systemone";

export interface LanguageJudgment {
  model: string;
  probability: number;
  usage?: Record<string, number>;
}

export interface LanguageClassifier {
  judgeMajorityEnglish(
    transcript: string,
    signal: AbortSignal,
  ): Promise<LanguageJudgment>;
}

interface TypeSafeLanguageClassifierOptions {
  fetchImpl?: typeof fetch;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const numericUsage = (value: unknown): Record<string, number> | undefined => {
  if (!isRecord(value)) {
    return undefined;
  }

  const usage: Record<string, number> = {};
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "number" && Number.isFinite(item)) {
      usage[key] = item;
    }
  }
  return Object.keys(usage).length > 0 ? usage : undefined;
};

const responseJudgment = (
  body: unknown,
  configuredModel: string,
): LanguageJudgment => {
  if (!isRecord(body) || typeof body.model !== "string" || !isRecord(body.answers)) {
    throw new ProviderFailureError();
  }

  const answer = body.answers.majority_english;
  if (!isRecord(answer) || answer.type !== "noul" || typeof answer.noul !== "number") {
    throw new ProviderFailureError();
  }
  if (!Number.isFinite(answer.noul) || answer.noul < 0 || answer.noul > 1) {
    throw new ProviderFailureError();
  }

  return {
    model: body.model || configuredModel,
    probability: answer.noul,
    usage: numericUsage(body.usage),
  };
};

export class TypeSafeLanguageClassifier implements LanguageClassifier {
  private readonly fetchImpl: typeof fetch;

  constructor(
    private readonly apiKey: string,
    private readonly model: string,
    options: TypeSafeLanguageClassifierOptions = {},
  ) {
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async judgeMajorityEnglish(
    transcript: string,
    signal: AbortSignal,
  ): Promise<LanguageJudgment> {
    let response: Response;
    try {
      response = await this.fetchImpl(typeSafeEndpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          state: { transcript },
          model: this.model,
          questions: {
            majority_english: {
              type: "noul",
              instructions:
                "Is the majority of the substantive linguistic content in `transcript` written in English?",
              criteria: {
                true: "The majority of meaningful words and sentences are English.",
                false: "The majority of meaningful words and sentences are not English.",
              },
            },
          },
        }),
        signal,
      });
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") {
        throw error;
      }
      throw new ProviderFailureError();
    }

    if (response.status === 401) {
      throw new ProviderAuthenticationError();
    }
    if (!response.ok) {
      throw new ProviderFailureError();
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new ProviderFailureError();
    }
    return responseJudgment(body, this.model);
  }
}

export function createTypeSafeLanguageClassifier(
  apiKey: string,
  model: string,
): TypeSafeLanguageClassifier {
  return new TypeSafeLanguageClassifier(apiKey, model);
}
