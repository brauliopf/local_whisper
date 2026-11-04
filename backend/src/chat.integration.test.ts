import assert from "node:assert/strict";
import { test } from "node:test";

const baseURL = process.env.INTEGRATION_API_URL?.replace(/\/$/, "");
const serviceToken = process.env.SERVICE_TOKEN;
const configured = Boolean(baseURL && serviceToken);

test(
  "real backend answers the cearense question",
  { skip: !configured ? "Set INTEGRATION_API_URL and SERVICE_TOKEN" : false },
  async () => {
    const response = await fetch(`${baseURL}/chat-completions`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${serviceToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ text: "what is cearense?" }),
      signal: AbortSignal.timeout(120_000),
    });

    const body = await response.json() as {
      text?: unknown;
      request_id?: unknown;
      error?: unknown;
    };

    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(typeof body.text, "string");
    assert.notEqual(body.text, "");
    assert.match(String(body.request_id), /^[0-9a-f-]{36}$/);
  },
);
