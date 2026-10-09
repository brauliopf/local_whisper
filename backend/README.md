# Local Whisper backend

The backend is a standalone Fastify API for the `local_whisper` macOS menu bar app. It accepts authenticated requests from the app, delegates AI work to configured providers, and returns concise results.

## Capabilities

- **Encouragement** — Generates a short encouragement message.
- **Transcription** — Transcribes M4A audio, detects whether the transcript is majority English with TypeSafe Jev when configured, and translates non-English-majority transcripts to English.
- **Screenshot OCR** — Extracts text from a JPEG or PNG screenshot.
- **Status** — Reports whether provider credentials are configured without exposing secret values or making provider calls.

The service exposes these endpoints:

```text
GET  /status
POST /encouragements
POST /transcriptions
POST /image-text
```

Except for `/status`, endpoints require an `Authorization: Bearer <service-token>` header. The deployed service is intended to be externally reachable over HTTPS and protected by this application-level bearer token; Cloud Run IAM authentication is not used by the standalone client.

## Provider responsibilities

OpenAI handles encouragement, transcription, translation, and image text extraction. TypeSafe is optional and is used only to classify whether a transcript is majority English. If TypeSafe is not configured, the backend translates every non-empty transcript. Provider API keys never need to be sent by the macOS client.

See [`AGENTS.md`](AGENTS.md) for the implementation map, local development workflow, configuration details, testing guidance, and deployment notes.
