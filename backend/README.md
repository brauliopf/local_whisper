# Local Whisper backend

Standalone Fastify API for screenshot OCR, encouragement, multilingual transcription, and the BRA-25 computer-use planner. OpenAI and TypeSafe credentials stay in the backend; the macOS app sends only the static service bearer token.

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
    "typesafe": { "configured": true },
    "computer_use": { "configured": true, "model": "gpt-4.1" }
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

### Computer-use sessions

Computer use is session-oriented. The backend plans executable Playwright JavaScript with OpenAI Responses API custom function calling; the macOS client executes it locally in a new visible browser and returns a fresh screenshot plus a bounded execution result.

`POST /computer-use/sessions` creates a session:

```sh
curl -sS http://127.0.0.1:8080/computer-use/sessions \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"instruction":"Find the cheapest flight","initial_url":"https://www.google.com","allowed_origins":["https://www.google.com"]}'
```

The response contains one generated module and its SHA-256 `code_hash`. Safe steps are immediately executable. `needs_user_approval` steps must be approved with:

```sh
curl -sS -X POST http://127.0.0.1:8080/computer-use/sessions/<session>/steps/<step>/approve \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"code_hash":"<exact-code-hash>","browser_state_hash":"<current-browser-state-hash>"}'
```

After local execution, upload exactly one PNG screenshot, a bounded JSON result, and browser metadata:

```sh
curl -sS -X POST http://127.0.0.1:8080/computer-use/sessions/<session>/steps/<step>/result \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -F 'screenshot=@/tmp/step.png;type=image/png' \
  -F 'result={"ok":true,"value":{"type":"table","columns":[],"rows":[],"notes":[]}};type=application/json' \
  -F 'current_url=https://www.google.com' \
  -F 'current_title=Google'
```

The service uses deterministic AST scanning before TypeSafe Jev risk classification. Syntax errors, executor-contract violations, host/credential access, browser cookies/storage, arbitrary network clients, dynamic code generation, and guardrail bypasses are permanently prohibited. Risky browser actions pause for one-time exact-code approval; approval never overrides permanent prohibitions. Sessions and bounded step metadata are stored in Firestore for 72 hours at most. Screenshots are forwarded transiently and are not written to Firestore.

## Local development

Copy `.env.example` to `.env` and provide an OpenAI key and service token. Add `TYPESAFE_API_KEY` when Jev classification is enabled; leaving it blank intentionally enables translation-only fallback. `.env` is ignored by Git.

```sh
cp .env.example .env
npm install
npm test
npm run dev
```

The service listens on `http://127.0.0.1:8080` by default. Local computer-use requests also require Application Default Credentials for Firestore and a configured `TYPESAFE_API_KEY`; without Jev, computer-use guardrails fail closed.

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

Grant only the Cloud Run service account access to Firestore (replace the placeholder with the account used by `local-whisper-api`):

```sh
gcloud projects add-iam-policy-binding local-whisper-509423 \
  --member="serviceAccount:<CLOUD_RUN_SERVICE_ACCOUNT>" \
  --role="roles/datastore.user"
```

Provision Firestore Native mode once in `local-whisper-509423`, grant the Cloud Run service account Firestore access, and configure TTL on the `expiresAt` field for both the root session collection and the `steps` collection group:

```sh
gcloud firestore databases create --project=local-whisper-509423 --location=us-west1 --type=firestore-native
gcloud firestore fields ttls update expiresAt --collection-group=computer_use_sessions --project=local-whisper-509423 --enable-ttl
gcloud firestore fields ttls update expiresAt --collection-group=steps --project=local-whisper-509423 --enable-ttl
```

The application still checks the 72-hour expiry on every request; Firestore TTL is cleanup rather than an authorization boundary. Do not grant the macOS app Firestore credentials.
