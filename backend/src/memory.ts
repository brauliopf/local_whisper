export class MemoryPersistenceError extends Error {
  constructor(
    readonly statusCode: number,
    readonly operation: string = "conversation_persistence",
  ) {
    super("Conversation message persistence failed");
    this.name = "MemoryPersistenceError";
  }
}

export type ConversationMessageRole = "user" | "assistant";

export interface ConversationMessage {
  role: ConversationMessageRole;
  content: string;
}

export interface ConversationStore {
  ensureConversation(conversationId: string, signal?: AbortSignal): Promise<void>;
  loadMessages(conversationId: string, signal?: AbortSignal): Promise<ConversationMessage[]>;
  appendMessage(
    conversationId: string,
    role: ConversationMessageRole,
    content: string,
    signal?: AbortSignal,
  ): Promise<void>;
}

const startupCheckTimeoutMs = 5_000;

export class PostgresConversationStore implements ConversationStore {
  constructor(
    private readonly baseURL: string,
    private readonly secretKey: string,
  ) {}

  async ensureConversation(conversationId: string, signal?: AbortSignal): Promise<void> {
    await this.post(
      "/rest/v1/conversations?on_conflict=id",
      { id: conversationId },
      signal,
      "resolution=ignore-duplicates",
      "ensure_conversation",
    );
  }

  async checkConnection(timeoutMs = startupCheckTimeoutMs): Promise<void> {
    for (const table of ["conversations", "messages"] as const) {
      const operation = `startup_check_${table}`;
      const signal = AbortSignal.timeout(timeoutMs);
      let response: Response;
      try {
        const url = new URL(`/rest/v1/${table}`, this.baseURL);
        url.searchParams.set(
          "select",
          table === "messages" ? "id,conversation_id,role,content" : "id",
        );
        url.searchParams.set("limit", "0");
        response = await fetch(url, {
          headers: {
            apikey: this.secretKey,
            authorization: `Bearer ${this.secretKey}`,
          },
          signal,
        });
      } catch {
        throw new MemoryPersistenceError(
          0,
          signal.aborted ? `${operation}_timeout` : operation,
        );
      }
      if (!response.ok) {
        throw new MemoryPersistenceError(response.status, operation);
      }
      try {
        const body: unknown = await response.json();
        if (!Array.isArray(body)) {
          throw new Error("Unexpected Supabase response");
        }
      } catch {
        throw new MemoryPersistenceError(
          response.status,
          signal.aborted ? `${operation}_timeout` : operation,
        );
      }
    }
  }

  async loadMessages(conversationId: string, signal?: AbortSignal): Promise<ConversationMessage[]> {
    const messages: ConversationMessage[] = [];
    let offset = 0;

    while (true) {
      const url = new URL("/rest/v1/messages", this.baseURL);
      url.searchParams.set("select", "role,content");
      url.searchParams.set("conversation_id", `eq.${conversationId}`);
      url.searchParams.set("order", "id.asc");

      let response: Response;
      try {
        response = await fetch(url, {
          headers: {
            apikey: this.secretKey,
            authorization: `Bearer ${this.secretKey}`,
            "Range-Unit": "items",
            Range: `${offset}-${offset + 999}`,
          },
          signal,
        });
      } catch (error) {
        if (signal?.aborted) throw error;
        throw new MemoryPersistenceError(0, "load_messages");
      }

      if (!response.ok) {
        throw new MemoryPersistenceError(response.status, "load_messages");
      }
      let page: ConversationMessage[];
      try {
        page = await response.json() as ConversationMessage[];
      } catch {
        throw new MemoryPersistenceError(response.status, "load_messages");
      }
      messages.push(...page);
      if (page.length === 0) return messages;
      offset += page.length;
    }
  }

  async appendMessage(
    conversationId: string,
    role: ConversationMessageRole,
    content: string,
    signal?: AbortSignal,
  ): Promise<void> {
    await this.post(
      "/rest/v1/messages",
      { conversation_id: conversationId, role, content },
      signal,
      undefined,
      `${role}_message_write`,
    );
  }

  private async post(
    path: string,
    body: unknown,
    signal?: AbortSignal,
    prefer?: string,
    operation = "conversation_persistence",
  ): Promise<void> {
    let response: Response;
    try {
      response = await fetch(`${this.baseURL}${path}`, {
        method: "POST",
        headers: {
          apikey: this.secretKey,
          authorization: `Bearer ${this.secretKey}`,
          "content-type": "application/json",
          ...(prefer ? { Prefer: prefer } : {}),
        },
        body: JSON.stringify(body),
        signal,
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new MemoryPersistenceError(0, operation);
    }

    if (!response.ok) {
      throw new MemoryPersistenceError(response.status, operation);
    }
  }
}
