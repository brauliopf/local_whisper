import assert from "node:assert/strict";
import { test } from "node:test";
import { MemoryPersistenceError, PostgresConversationStore } from "./memory.js";

test("startup check verifies both Supabase conversation tables", async (t) => {
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    requests.push(`${url.pathname}?${url.searchParams}`);
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-secret");
    assert.equal(new Headers(init?.headers).get("apikey"), "test-secret");
    return Response.json([]);
  };

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  await store.checkConnection();
  assert.deepEqual(requests, [
    "/rest/v1/conversations?select=id&limit=0",
    "/rest/v1/messages?select=id%2Cconversation_id%2Crole%2Ccontent&limit=0",
  ]);
});

test("startup check bounds probes and identifies timeout safely", async (t) => {
  const originalFetch = globalThis.fetch;
  const keepEventLoopAlive = setTimeout(() => {}, 50);
  t.after(() => {
    clearTimeout(keepEventLoopAlive);
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async (_input, init) => new Promise<Response>((_resolve, reject) => {
    init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
  });

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  await assert.rejects(store.checkConnection(5), (error: unknown) => {
    assert.ok(error instanceof MemoryPersistenceError);
    assert.equal(error.statusCode, 0);
    assert.equal(error.operation, "startup_check_conversations_timeout");
    assert.equal(error.message.includes("test-secret"), false);
    return true;
  });
});

test("startup check exposes the failing table and status without secret values", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return calls === 1
      ? Response.json([])
      : new Response("denied", { status: 401 });
  };

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  await assert.rejects(store.checkConnection(), (error: unknown) => {
    assert.ok(error instanceof MemoryPersistenceError);
    assert.equal(error.statusCode, 401);
    assert.equal(error.operation, "startup_check_messages");
    assert.equal(error.message.includes("test-secret"), false);
    return true;
  });
});

test("assistant persistence errors identify the failed operation", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async () => new Response("unavailable", { status: 500 });

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  await assert.rejects(store.appendMessage("conversation-1", "assistant", "reply"), (error: unknown) => {
    assert.ok(error instanceof MemoryPersistenceError);
    assert.equal(error.operation, "assistant_message_write");
    assert.equal(error.statusCode, 500);
    return true;
  });
});

test("inserts complete account-scoped entity records through PostgREST", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  let requestURL = "";
  let requestBody = "";
  globalThis.fetch = async (input, init) => {
    requestURL = String(input);
    requestBody = String(init?.body);
    assert.equal(init?.method, "POST");
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-secret");
    return Response.json([]);
  };

  const store = new PostgresConversationStore("https://example.supabase.co", "test-secret");
  await store.appendEntities("account-1", [{
    name: "Lina",
    type: "PERSON",
    description: "I'll pick up Lina at school.",
    embedding: [0.1, 0.2],
  }]);

  assert.equal(new URL(requestURL).pathname, "/rest/v1/entities");
  assert.deepEqual(JSON.parse(requestBody), [{
    name: "Lina",
    type: "PERSON",
    description: "I'll pick up Lina at school.",
    embedding: [0.1, 0.2],
    account_id: "account-1",
  }]);
});

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
