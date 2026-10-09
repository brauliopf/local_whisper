# Backend instructions

The root [`AGENTS.md`](../AGENTS.md) defines repository-wide editing, testing, validation, and security rules. This file contains backend-specific guidance only.

## Development

Run from `backend/`:

```sh
npm ci
npm test
npm run dev
```

`npm test` builds TypeScript and runs the compiled Node tests. Use `npm run build` for compilation only and `npm start` for the compiled server. The development server defaults to `http://127.0.0.1:8080`.

Use `.env.example` as the configuration reference. Required values are `OPENAI_API_KEY` and `SERVICE_TOKEN`; `TYPESAFE_API_KEY` is optional. Do not use production credentials in tests.

## Code boundaries

- `src/server.ts` — composition root and server startup.
- `src/config.ts` — environment parsing, defaults, and validation.
- `src/app.ts` — HTTP routes, authentication, multipart validation, limits, rate limiting, deadlines, and public errors.
- `src/provider.ts` — OpenAI provider adapter.
- `src/transcription.ts` — transcription, language classification, translation, cancellation, and timeouts.
- `src/typesafe.ts` — TypeSafe Jev adapter.
- `src/prompts.ts` — backend-owned prompts.
- `src/rate-limit.ts` — in-memory rate limiter.
- `src/errors.ts` — API error types.
- `src/*.test.ts` — backend tests.

Edit `src/`; `dist/` is generated output.

Keep the client contract stable:

- `GET /status` is unauthenticated.
- `POST /encouragements` accepts `{}`.
- `POST /transcriptions` accepts one M4A file named `audio`.
- `POST /image-text` accepts one JPEG or PNG file named `image`.
- Protected routes use the `Authorization: Bearer <SERVICE_TOKEN>` header.
- Successful operation responses include `request_id`.

The client contract is implemented in `../local_whisper/Shared/Backend/BackendClient.swift`.

## Backend validation

The root [`clean-state-checklist.md`](../clean-state-checklist.md) is authoritative. The backend-specific automated baseline is:

```sh
npm test
```

The independent validator must also run the root gate and backend runtime smoke checks. Do not claim backend readiness from compilation alone.

## Deployment

The service runs on Google Cloud Run:

- Project: `local-whisper-509423`
- Region: `us-west1`
- Service: `local-whisper-api`
- Base URL: `https://local-whisper-api-24n67dikla-uw.a.run.app`

Inject `OPENAI_API_KEY`, `SERVICE_TOKEN`, and optional `TYPESAFE_API_KEY` from Google Secret Manager. The deployed `SERVICE_TOKEN` must match the token stored in the macOS app Keychain. Cloud Run IAM authentication is not used by the client.
