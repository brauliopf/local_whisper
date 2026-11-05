import assert from "node:assert/strict";
import { test } from "node:test";
import { PostgresConversationStore } from "./memory.js";

test("loads all messages across ordered PostgREST pages", async (t) => {
  const originalFetch = globalThis.fetch;
  const expected = Array.from({ length: 1001 }, (_, index) => ({
    role: index % 2 === 0 ? "user" as const : "assistant" as const,
    content: `message-${index}`,
  }));
  const ranges: string[] = [];

  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    assert.equal(url.searchParams.get("conversation_id"), "eq.conversation-1");
    assert.equal(url.searchParams.get("order"), "id.asc");
    const range = new Headers(init?.headers).get("range");
    assert.ok(range);
    ranges.push(range);
    const [start, end] = range.split("-").map(Number);
    return new Response(JSON.stringify(expected.slice(start, end + 1)), {
      status: 206,
      headers: { "content-type": "application/json" },
    });
  };

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  assert.deepEqual(await store.loadMessages("conversation-1"), expected);
  assert.deepEqual(ranges, ["0-999", "1000-1999", "1001-2000"]);
});
