# Local Whisper backend

Standalone Phase 1 API for screenshot text extraction. The existing macOS app is not part of this service and is not changed by this package.

## API

### Status check

```http
GET /status
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

## Local development

Copy `.env.example` to `.env` and provide an OpenAI key and service token. `.env` is ignored by Git.

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

The first deployment target is the `local-whisper-509423` project in `us-west1`, with service name `local-whisper-api`. Store `OPENAI_API_KEY` and `SERVICE_TOKEN` in Secret Manager; do not put either value in a deployment command or checked-in file.

The service is intended to be externally reachable over HTTPS and protected by its application bearer token. Cloud Run IAM authentication is not used by the standalone curl client.
