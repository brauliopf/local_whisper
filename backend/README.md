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

`SUPABASE_URL` and `SUPABASE_SECRET_KEY` are required at backend startup. Before listening, the server verifies that the `conversations` table exposes `id` and the `messages` table exposes `id`, `conversation_id`, `role`, and `content` to the configured key. Each table probe has a five-second timeout; startup exits with a logged error if configuration, connectivity, or a required column check fails. This confirms read access to the listed columns, not insert permissions. Conversation IDs are limited to 1024 UTF-8 bytes. The backend creates or reuses a conversation, writes the user message before calling the provider, then writes the assistant message after completion. The separate database writes preserve their actual write timestamps; if completion or assistant-message persistence fails, the user message remains without an assistant message. Persistence errors are logged with request ID, operation, and status only; prompt contents and credentials are not logged. Raw audio is never stored. Apply `supabase/migrations/20261104225716_create_conversations_and_messages.sql` before deploying.

See [`AGENTS.md`](AGENTS.md) for the implementation map, local development workflow, configuration details, testing guidance, and deployment notes.
