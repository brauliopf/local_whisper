import assert from "node:assert/strict";
import { test } from "node:test";
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
import { TranscriptionWorkflow } from "./transcription.js";
import { TypeSafeLanguageClassifier } from "./typesafe.js";

const audio = Buffer.from("audio");
const mediaType: AudioMediaType = "audio/mp4";

class FakeTranscriber implements TranscriptionProvider {
  calls = 0;

  constructor(private readonly text: string) {}

  async transcribeAudio(): Promise<string> {
    this.calls += 1;
    return this.text;
  }
}

class FakeTranslator implements TranslationProvider {
  calls: string[] = [];

  constructor(private readonly result = "translated text") {}

  async translateToEnglish(text: string): Promise<string> {
    this.calls.push(text);
    return this.result;
  }
}

function workflow({
  transcript = "Bonjour tout le monde",
  probability,
  classifier,
  translation = "Hello everyone",
  maxTranscriptChars = 20_000,
}: {
  transcript?: string;
  probability?: number;
  classifier?: {
    judgeMajorityEnglish(
      transcript: string,
      signal: AbortSignal,
    ): Promise<{ model: string; probability: number }>;
  };
  translation?: string;
  maxTranscriptChars?: number;
} = {}) {
  const transcriber = new FakeTranscriber(transcript);
  const translator = new FakeTranslator(translation);
  const selectedClassifier = classifier ?? (probability === undefined
    ? undefined
    : {
        async judgeMajorityEnglish() {
          return { model: "test-jev", probability };
        },
      });
  const service = new TranscriptionWorkflow({
    transcriber,
    translator,
    classifier: selectedClassifier,
    transcriptionTimeoutMs: 100,
    typesafeTimeoutMs: 100,
    translationTimeoutMs: 100,
    maxTranscriptChars,
  });
  return { service, transcriber, translator };
}

test("keeps a majority-English transcript without translating", async () => {
  const { service, translator } = workflow({
    transcript: "This is already English.",
    probability: 0.9,
  });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.deepEqual(result, {
    text: "This is already English.",
    isTranslated: false,
    branch: "original",
    languageJudgment: { model: "test-jev", probability: 0.9 },
  });
  assert.deepEqual(translator.calls, []);
});

test("translates when Noul is below the threshold", async () => {
  const { service, translator } = workflow({ probability: 0.49 });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.equal(result.text, "Hello everyone");
  assert.equal(result.isTranslated, true);
  assert.equal(result.branch, "translate");
  assert.deepEqual(translator.calls, ["Bonjour tout le monde"]);
});

test("keeps the original transcript at the 0.5 threshold", async () => {
  const { service, translator } = workflow({
    transcript: "Mixed content",
    probability: 0.5,
  });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.equal(result.text, "Mixed content");
  assert.equal(result.isTranslated, false);
  assert.deepEqual(translator.calls, []);
});

test("translates every non-empty transcript when TypeSafe is unconfigured", async () => {
  const { service, translator } = workflow({
    transcript: "This may already be English.",
  });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.equal(result.isTranslated, true);
  assert.equal(result.branch, "translate_fallback");
  assert.equal(result.fallbackReason, "typesafe_unconfigured");
  assert.deepEqual(translator.calls, ["This may already be English."]);
});

test("falls back to translation after a TypeSafe provider failure", async () => {
  const { service, translator } = workflow({
    classifier: {
      async judgeMajorityEnglish() {
        throw new ProviderTimeoutError();
      },
    },
  });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.equal(result.isTranslated, true);
  assert.equal(result.branch, "translate_fallback");
  assert.equal(result.fallbackReason, "typesafe_timeout");
  assert.deepEqual(translator.calls, ["Bonjour tout le monde"]);
});

test("skips TypeSafe and translation for an empty transcript", async () => {
  const { service, translator, transcriber } = workflow({ transcript: "  " });

  const result = await service.transcribeAudio(audio, mediaType, new AbortController().signal);

  assert.deepEqual(result, {
    text: "",
    isTranslated: false,
    branch: "original",
  });
  assert.equal(transcriber.calls, 1);
  assert.deepEqual(translator.calls, []);
});

test("rejects oversized transcripts without translating", async () => {
  const { service, translator } = workflow({
    transcript: "12345",
    maxTranscriptChars: 4,
  });

  await assert.rejects(
    service.transcribeAudio(audio, mediaType, new AbortController().signal),
    ProviderFailureError,
  );
  assert.deepEqual(translator.calls, []);
});

test("does not fall back after cancellation", async () => {
  const controller = new AbortController();
  const { service, translator } = workflow({
    classifier: {
      async judgeMajorityEnglish() {
        controller.abort();
        throw new ProviderFailureError();
      },
    },
  });

  await assert.rejects(
    service.transcribeAudio(audio, mediaType, controller.signal),
    ProviderFailureError,
  );
  assert.deepEqual(translator.calls, []);
});

test("rejects empty translation output", async () => {
  const { service } = workflow({ probability: 0.1, translation: "  " });

  await assert.rejects(
    service.transcribeAudio(audio, mediaType, new AbortController().signal),
    ProviderFailureError,
  );
});

test("parses the TypeSafe Noul response and sends the structured transcript state", async () => {
  let requestBody: unknown;
  let authorization: string | null = null;
  const classifier = new TypeSafeLanguageClassifier(
    "typesafe-secret",
    "jev-1.13.0",
    {
      fetchImpl: async (_input, init) => {
        requestBody = JSON.parse(String(init?.body));
        authorization = new Headers(init?.headers).get("authorization");
        return new Response(
          JSON.stringify({
            model: "jev-1.13.0",
            answers: {
              majority_english: { type: "noul", noul: 0.82 },
            },
            usage: { input_tokens: 12, output_tokens: 4 },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    },
  );

  const judgment = await classifier.judgeMajorityEnglish(
    "This is a transcript.",
    new AbortController().signal,
  );

  assert.deepEqual(judgment, {
    model: "jev-1.13.0",
    probability: 0.82,
    usage: { input_tokens: 12, output_tokens: 4 },
  });
  assert.equal(authorization, "Bearer typesafe-secret");
  assert.deepEqual(requestBody, {
    state: { transcript: "This is a transcript." },
    model: "jev-1.13.0",
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
  });
});

test("normalizes TypeSafe authentication and malformed responses", async () => {
  const authenticationClassifier = new TypeSafeLanguageClassifier(
    "typesafe-secret",
    "jev-1.13.0",
    {
      fetchImpl: async () => new Response("", { status: 401 }),
    },
  );
  await assert.rejects(
    authenticationClassifier.judgeMajorityEnglish("text", new AbortController().signal),
    ProviderAuthenticationError,
  );

  const malformedClassifier = new TypeSafeLanguageClassifier(
    "typesafe-secret",
    "jev-1.13.0",
    {
      fetchImpl: async () =>
        new Response(JSON.stringify({ answers: {} }), { status: 200 }),
    },
  );
  await assert.rejects(
    malformedClassifier.judgeMajorityEnglish("text", new AbortController().signal),
    ProviderFailureError,
  );
});
