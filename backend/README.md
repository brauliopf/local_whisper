# Local Whisper backend

Standalone Phase 1 API for screenshot text extraction. The existing macOS app is not part of this service and is not changed by this package.

## API

### Status check

```http
GET /status
```

The unauthenticated response reports whether backend provider credentials are configured, without exposing key values or making live provider calls:

```json
{
  "status": "ok",
  "providers": {
    "openai": { "configured": true },
    "typesafe": { "configured": true }
  }
}
```

### Extract text from an image

```http
POST /image-text
Authorization: Bearer <service-token>
Content-Type: multipart/form-data
```

The multipart request must contain exactly one JPEG or PNG file field named `image`.

Success:

```json
{
  "text": "Extracted text",
  "request_id": "..."
}
```

When no readable text is found, `text` is `null`.

### Fetch encouragement

```http
POST /encouragements
Authorization: Bearer <service-token>
Content-Type: application/json

{}
```

The backend owns the encouragement prompt and returns one short sentence with at most 15 words.

### Transcribe and translate audio

```http
POST /transcriptions
Authorization: Bearer <service-token>
Content-Type: multipart/form-data
```

The multipart request must contain exactly one M4A file field named `audio`. The backend transcribes the source language with `whisper-1`, then uses TypeSafe Jev's Noul judgment to decide whether the transcript is majority English. Non-English-majority transcripts are translated to English by the backend.

If `TYPESAFE_API_KEY` is blank or TypeSafe is unavailable, the backend translates every non-empty transcript. The client does not provide a language, model, prompt, or provider key.

Success:

```json
{
  "text": "The final transcript or English translation.",
  "is_translated": true,
  "request_id": "..."
}
```

`is_translated` is informational API metadata. The macOS client continues to copy only `text`.

The workflow skips Jev and translation for empty transcription output. Client cancellation and request deadlines abort the workflow rather than starting fallback translation.

## Local development

Copy `.env.example` to `.env` and provide an OpenAI key and service token. Add `TYPESAFE_API_KEY` when Jev classification is enabled; leaving it blank intentionally enables translation-only fallback. `.env` is ignored by Git.

```sh
cp .env.example .env
npm install
npm test
npm run dev
```

The service listens on `http://127.0.0.1:8080` by default.

A request from curl uses the `image` form-data field and the bearer token from `.env`:

```sh
curl -i http://127.0.0.1:8080/image-text \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -F "image=@/path/to/screenshot.png;type=image/png"
```

For the deployed service, the current base URL is:

```text
https://local-whisper-api-24n67dikla-uw.a.run.app
```

## Cloud Run

The first deployment target is the `local-whisper-509423` project in `us-west1`, with service name `local-whisper-api`. Store `OPENAI_API_KEY`, `SERVICE_TOKEN`, and (when enabled) `TYPESAFE_API_KEY` in Secret Manager; do not put any value in a deployment command or checked-in file. `TYPESAFE_API_KEY` is optional at runtime.

The service is intended to be externally reachable over HTTPS and protected by its application bearer token. Cloud Run IAM authentication is not used by the standalone curl client.
