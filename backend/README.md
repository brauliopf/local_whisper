# Local Whisper backend

The backend is a standalone Fastify API for the `local_whisper` macOS menu bar app. It accepts authenticated requests from the app, delegates AI work to configured providers, and returns concise results.

## Capabilities

- **Encouragement** — Generates a short encouragement message.
- **Transcription** — Transcribes M4A audio, detects whether the transcript is majority English with TypeSafe Jev when configured, and translates non-English-majority transcripts to English.
- **Screenshot OCR** — Extracts text from a JPEG or PNG screenshot.
- **Chat completion** — Completes a text prompt and persists the user/assistant turn in the backend-owned ConversationStore.
- **Status** — Reports whether provider credentials are configured without exposing secret values or making provider calls.

The service exposes these endpoints:

```text
GET  /status
POST /encouragements
POST /transcriptions
POST /image-text
POST /chat-completions
```

Except for `/status`, endpoints require an `Authorization: Bearer <service-token>` header. The deployed service is intended to be externally reachable over HTTPS and protected by this application-level bearer token; Cloud Run IAM authentication is not used by the standalone client.

## Provider responsibilities

OpenAI handles encouragement, transcription, translation, image text extraction, and chat completions. TypeSafe is optional and is used only to classify whether a transcript is majority English. If TypeSafe is not configured, the backend translates every non-empty transcript. Provider API keys never need to be sent by the macOS client.

`POST /chat-completions` requires `SUPABASE_URL` and `SUPABASE_SECRET_KEY`. If either is missing, it fails with `503 conversation_store_unavailable` before calling the provider. Conversation IDs are limited to 1024 UTF-8 bytes. The backend creates or reuses a conversation, writes the user message before calling the provider, then writes the assistant message after completion. When `conversation_id` is supplied, it loads the conversation's full ordered message history (including the current user message) and sends it to the provider as role-tagged input; without an ID, it sends only the current prompt. The separate database writes preserve their actual write timestamps; if completion or assistant-message persistence fails, the user message remains without an assistant message. Raw audio is never stored. Apply `supabase/migrations/20261104225716_create_conversations_and_messages.sql` before enabling chat persistence.

See [`AGENTS.md`](AGENTS.md) for the implementation map, local development workflow, configuration details, testing guidance, and deployment notes.
