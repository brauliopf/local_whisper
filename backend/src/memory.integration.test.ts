import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { PostgresConversationStore } from "./memory.js";
import { defaultAccountId } from "./entity-memory.js";
import { entityEmbeddingDimensions } from "./provider.js";

const baseURL = process.env.SUPABASE_URL?.replace(/\/$/, "");
const secretKey = process.env.SUPABASE_SECRET_KEY;
const configured = Boolean(baseURL && secretKey);

const headers = () => ({
  apikey: secretKey!,
  authorization: `Bearer ${secretKey!}`,
});

test(
  "ConversationStore persists messages in order with database timestamps",
  { skip: !configured ? "Set SUPABASE_URL and SUPABASE_SECRET_KEY" : false },
  async () => {
    const conversationId = `integration-${randomUUID()}`;
    const store = new PostgresConversationStore(baseURL!, secretKey!);
    let conversationCreated = false;

    try {
      await store.ensureConversation(conversationId);
      conversationCreated = true;
      await store.appendMessage(conversationId, "user", "what is cearense?");
      await store.appendMessage(
        conversationId,
        "assistant",
        "A person or thing from Ceará.",
      );
      assert.deepEqual(await store.loadMessages(conversationId), [
        { role: "user", content: "what is cearense?" },
        { role: "assistant", content: "A person or thing from Ceará." },
      ]);

      const conversationQuery = new URLSearchParams({ select: "id", id: `eq.${conversationId}` });
      const conversationResponse = await fetch(
        `${baseURL}/rest/v1/conversations?${conversationQuery}`,
        { headers: headers() },
      );
      const conversationBody = await conversationResponse.text();
      assert.equal(conversationResponse.status, 200, conversationBody);
      assert.deepEqual(JSON.parse(conversationBody), [{ id: conversationId }]);

      const messagesQuery = new URLSearchParams({
        select: "role,content,created_at",
        conversation_id: `eq.${conversationId}`,
        order: "id.asc",
      });
      const messagesResponse = await fetch(
        `${baseURL}/rest/v1/messages?${messagesQuery}`,
        { headers: headers() },
      );
      const messagesBody = await messagesResponse.text();
      assert.equal(messagesResponse.status, 200, messagesBody);
      const messages = JSON.parse(messagesBody) as Array<{
        role: string;
        content: string;
        created_at: string;
      }>;
      assert.deepEqual(messages.map(({ role, content }) => ({ role, content })), [
        { role: "user", content: "what is cearense?" },
        { role: "assistant", content: "A person or thing from Ceará." },
      ]);
      assert.ok(Date.parse(messages[1]!.created_at) >= Date.parse(messages[0]!.created_at));
    } finally {
      if (conversationCreated) {
        const messagesCleanup = await fetch(
          `${baseURL}/rest/v1/messages?conversation_id=eq.${encodeURIComponent(conversationId)}`,
          { method: "DELETE", headers: headers() },
        );
        assert.ok(messagesCleanup.ok, await messagesCleanup.text());
        const conversationCleanup = await fetch(
          `${baseURL}/rest/v1/conversations?id=eq.${encodeURIComponent(conversationId)}`,
          { method: "DELETE", headers: headers() },
        );
        assert.ok(conversationCleanup.ok, await conversationCleanup.text());
      }
    }
  },
);

test(
  "PostgREST stores account-scoped entities with vector embeddings",
  { skip: !configured ? "Set SUPABASE_URL and SUPABASE_SECRET_KEY" : false },
  async () => {
    const entityName = `integration-${randomUUID()}`;
    const store = new PostgresConversationStore(baseURL!, secretKey!);
    let entityCreated = false;

    try {
      await store.appendEntities(defaultAccountId, [{
        name: entityName,
        type: "SYSTEM",
        description: `Integration test entity ${entityName}`,
        embedding: Array(entityEmbeddingDimensions).fill(0),
      }]);
      entityCreated = true;

      const query = new URLSearchParams({
        select: "name,type,description,account_id,embedding",
        name: `eq.${entityName}`,
      });
      const response = await fetch(`${baseURL}/rest/v1/entities?${query}`, { headers: headers() });
      const body = await response.text();
      assert.equal(response.status, 200, body);
      const rows = JSON.parse(body) as Array<{
        name: string;
        type: string;
        description: string;
        account_id: string;
        embedding: string | number[];
      }>;
      assert.equal(rows.length, 1);
      assert.equal(rows[0]?.name, entityName);
      assert.equal(rows[0]?.type, "SYSTEM");
      assert.equal(rows[0]?.account_id, defaultAccountId);
      const embedding = typeof rows[0]?.embedding === "string"
        ? JSON.parse(rows[0].embedding)
        : rows[0]?.embedding;
      assert.equal(embedding?.length, entityEmbeddingDimensions);
      assert.equal(embedding?.[0], 0);
    } finally {
      if (entityCreated) {
        const cleanup = await fetch(
          `${baseURL}/rest/v1/entities?name=eq.${encodeURIComponent(entityName)}`,
          { method: "DELETE", headers: headers() },
        );
        assert.ok(cleanup.ok, await cleanup.text());
      }
    }
  },
);
