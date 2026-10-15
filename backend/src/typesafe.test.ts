import assert from "node:assert/strict";
import test from "node:test";
import { ProviderAuthenticationError, ProviderFailureError } from "./errors.js";
import { TypeSafeBrowserSafetyReviewer } from "./typesafe.js";

const input = {
  goal: "Open a public page",
  code: "await page.goto('https://example.com');",
  capabilityPolicy: { allowed_actions: ["navigate"] },
  deterministicViolations: [],
  deterministicPassed: false,
  redactedPageState: { url: "about:blank" },
};

function reviewerWith(response: Response | Error): TypeSafeBrowserSafetyReviewer {
  return new TypeSafeBrowserSafetyReviewer("test-key", "jev-test", {
    fetchImpl: async () => {
      if (response instanceof Error) throw response;
      return response;
    },
  });
}

test("approves a well-formed browser safety response", async () => {
  const reviewer = reviewerWith(new Response(JSON.stringify({
    model: "jev-test",
    answers: Object.fromEntries([
      "goal_alignment",
      "allowed_capabilities",
      "safe_data_handling",
      "single_tab",
      "untrusted_page",
    ].map((name) => [name, { type: "noul", noul: 0.9 }])),
  }), { status: 200 }));
  const result = await reviewer.reviewBrowserPlan(input, new AbortController().signal);
  assert.equal(result.approved, true);
  assert.equal(result.checks.single_tab, 0.9);
});

test("returns rejected for a well-formed failing response", async () => {
  const answers = Object.fromEntries([
    "goal_alignment",
    "allowed_capabilities",
    "safe_data_handling",
    "single_tab",
    "untrusted_page",
  ].map((name) => [name, { type: "noul", noul: name === "allowed_capabilities" ? 0.2 : 0.9 }]));
  const reviewer = reviewerWith(new Response(JSON.stringify({ model: "jev-test", answers }), { status: 200 }));
  const result = await reviewer.reviewBrowserPlan(input, new AbortController().signal);
  assert.equal(result.approved, false);
});

test("rejects malformed and HTTP error responses", async () => {
  await assert.rejects(
    reviewerWith(new Response(JSON.stringify({ model: "jev-test", answers: {} }), { status: 200 }))
      .reviewBrowserPlan(input, new AbortController().signal),
    ProviderFailureError,
  );
  await assert.rejects(
    reviewerWith(new Response("", { status: 401 })).reviewBrowserPlan(input, new AbortController().signal),
    ProviderAuthenticationError,
  );
  await assert.rejects(
    reviewerWith(new Response("", { status: 500 })).reviewBrowserPlan(input, new AbortController().signal),
    ProviderFailureError,
  );
});

test("preserves cancellation from the TypeSafe request", async () => {
  const error = new Error("aborted");
  error.name = "AbortError";
  const reviewer = reviewerWith(error);
  await assert.rejects(
    reviewer.reviewBrowserPlan(input, new AbortController().signal),
    (reason: unknown) => reason === error,
  );
});
