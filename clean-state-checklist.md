# Clean-state checklist

This checklist is the validation gate for changes to the backend and the macOS Swift app. Run it from the repository root after implementation and before declaring the application ready. A clean state means every applicable check passes, or an exception is documented with its reason and follow-up.

The automated portion can be run with:

```sh
bash scripts/clean_state_check.sh
```

That command runs the backend tests, backend smoke checks, architecture boundary checks, and the Swift build/tests. The remaining interactive macOS checks in this document still require a test-machine session.

## Validation gate and roles

The implementation model prepares the change but is not the final judge. It must request approval before starting validation, then hand this checklist and the current repository state to an independent validator model. The validator model runs the commands itself and returns one explicit verdict:

- `PASS` only when every applicable check passes.
- `FAIL` when any check fails, cannot be run, or lacks sufficient evidence.

The validator report must include the commands run, checks passed, checks failed, raw or summarized output, and a detailed actionable explanation for every failure. A failure explanation must identify the failing check, relevant file or command, observed behavior, likely cause, and the next corrective action. After a fix, the implementation model must request a fresh validation pass; it must not reuse its own execution as the independent verdict.

## Validation rules

- Start from the current working tree and preserve unrelated user changes.
- Do not use production credentials for local checks.
- Do not treat a successful build as proof of correct runtime behavior; run the focused tests and smoke checks as well.
- Record the commands, pass/fail result, and any intentionally skipped check in the change summary.
- Fix failures and rerun the affected section. Do not hide failures by weakening tests or deleting generated output required by the project.

## Backend

Run these commands from `backend/`.

### Build checks

- [ ] Install dependencies from the lockfile: `npm ci`
- [ ] Compile TypeScript with no errors: `npm run build`
- [ ] Run the complete backend test suite: `npm test`
- [ ] Confirm generated output exists for every compiled source module and that source changes were made under `src/`, not manually under `dist/`:

  ```sh
  test -f dist/server.js
  test -f dist/app.js
  test -f dist/config.js
  test -f dist/transcription.js
  ```

### Architecture checks

- [ ] Confirm the server composition remains explicit: configuration, provider, and transcription workflow are assembled in `src/server.ts`.

  ```sh
  rg -n "loadConfig|createOpenAIImageTextProvider|TranscriptionWorkflow|buildApp" src/server.ts
  ```

- [ ] Confirm HTTP concerns remain in the Fastify app layer and provider calls remain behind provider/workflow abstractions:

  ```sh
  rg -n "onRequest|Authorization|multipart|rateLimit|runWithDeadline" src/app.ts
  rg -n "BackendProvider|openai|transcribeAudio|translateToEnglish" src/provider.ts
  rg -n "TranscriptionWorkflow|judgeMajorityEnglish|translateToEnglish" src/transcription.ts
  ```

- [ ] Confirm the API contract has not drifted from the macOS client. These route and multipart field names must remain present:

  ```sh
  rg -n '/status' src/app.ts
  rg -n '/image-text' src/app.ts
  rg -n '/encouragements' src/app.ts
  rg -n '/transcriptions' src/app.ts
  rg -n 'fieldName: "image"' ../local_whisper/Shared/Backend/BackendClient.swift
  rg -n 'fieldName: "audio"' ../local_whisper/Shared/Backend/BackendClient.swift
  ```

- [ ] Confirm secrets are loaded from environment variables and are not hard-coded:

  ```sh
  rg -n 'OPENAI_API_KEY|SERVICE_TOKEN|TYPESAFE_API_KEY' src .env.example
  ! rg -n 'sk-[A-Za-z0-9]|Bearer [^<[:space:]]+' src
  ```

### Runtime checks

- [ ] Start the compiled server with non-production test values. `/status` must work without calling an external provider:

  ```sh
  set -eu
  PORT=18080 OPENAI_API_KEY=test-openai-key SERVICE_TOKEN=test-service-token \
    node dist/server.js > /tmp/local-whisper-backend.log 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT

  for attempt in $(seq 1 20); do
    if curl --silent --fail http://127.0.0.1:18080/status > /tmp/local-whisper-status.json; then
      break
    fi
    sleep 0.25
  done

  grep -q '"status":"ok"' /tmp/local-whisper-status.json
  grep -q '"openai":{"configured":true}' /tmp/local-whisper-status.json
  ```

- [ ] Confirm protected endpoints reject missing authentication:

  ```sh
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18080/encouragements \
    -H 'Content-Type: application/json' -d '{}')" = 401
  ```

- [ ] Confirm an incorrect token is rejected and the configured token is accepted far enough to validate the request:

  ```sh
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18080/encouragements \
    -H 'Authorization: Bearer wrong-token' \
    -H 'Content-Type: application/json' -d '{}')" = 401

  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18080/encouragements \
    -H 'Authorization: Bearer test-service-token' \
    -H 'Content-Type: application/json' -d '{"unexpected":true}')
  test "$code" = 400
  ```

- [ ] Confirm the server exits cleanly after the smoke check and inspect `/tmp/local-whisper-backend.log` for unexpected startup or shutdown errors.

## macOS Swift app

Run these commands from the repository root. Use the same Xcode version and macOS SDK required by the project.

### Build checks

- [ ] Build the app target:

  ```sh
  xcodebuild -project local_whisper.xcodeproj \
    -scheme local_whisper \
    -configuration Debug \
    -destination 'platform=macOS' \
    build
  ```

- [ ] Run the Swift unit tests:

  ```sh
  xcodebuild -project local_whisper.xcodeproj \
    -scheme local_whisper \
    -destination 'platform=macOS' \
    test
  ```

- [ ] Confirm the test target is present and both current test files are included by the synchronized test group:

  ```sh
  rg -n 'local_whisperTests|PBXFileSystemSynchronizedRootGroup' local_whisper.xcodeproj/project.pbxproj
  test -f local_whisperTests/CountdownTests.swift
  test -f local_whisperTests/TimerSettingsTests.swift
  ```

### Architecture checks

- [ ] Confirm the app remains a menu bar application with one coordinator and the expected feature owners:

  ```sh
  rg -n '@main|NSApplicationDelegateAdaptor|LSUIElement' local_whisper local_whisper.xcodeproj
  rg -n 'final class AppCoordinator|final class Encouragement|final class VoiceTranscription|final class ScreenshotOCR|final class Countdown' local_whisper
  ```

- [ ] Confirm global shortcut registration stays centralized and the expected shortcuts remain wired:

  ```sh
  rg -n 'RegisterEventHotKey|kVK_ANSI_E|kVK_ANSI_W|kVK_ANSI_R|kVK_ANSI_T|kVK_ANSI_S' local_whisper/Shared/Hotkeys.swift
  ```

- [ ] Confirm backend calls go through `BackendClient`, and the app does not contain provider API keys or direct OpenAI calls:

  ```sh
  rg -n 'BackendClient|BackendClienting|Authorization' local_whisper/Shared/Backend local_whisper
  ! rg -n 'OPENAI_API_KEY|sk-[A-Za-z0-9]|api\.openai\.com' local_whisper
  ```

- [ ] Confirm sensitive app storage and user-facing settings remain separated from feature orchestration:

  ```sh
  rg -n 'SecItem(Add|CopyMatching)|KeychainStore' local_whisper/Shared
  rg -n 'SettingsView|TimerSettings|TelemetrySettings' local_whisper/Shared
  rg -n 'AppCoordinator' local_whisper/App
  ```

- [ ] Confirm the app and test source trees remain separate synchronized groups:

  ```sh
  rg -n 'PBXFileSystemSynchronizedRootGroup|path = local_whisper;|path = local_whisperTests;' \
    local_whisper.xcodeproj/project.pbxproj
  ```

### Runtime checks

- [ ] Confirm the unit tests cover observable timer behavior, including start, extension, completion sound, and persisted settings. The test command above must pass; these test names must remain present:

  ```sh
  rg -n 'func test(StartOrExtend|Completion|RepeatedExtensions|CompletionSound)' local_whisperTests
  ```

- [ ] Launch the Debug app from Xcode or the built `.app` and verify the menu bar item appears without a Dock icon.

- [ ] Verify the following menu bar and shortcut flows on a test machine:
  - `⌃⌥S` opens Settings and saving a token succeeds.
  - `⌃⌥T` starts the configured timer; the remaining time appears beside the icon; pressing it again extends the running timer by five minutes.
  - `⌃⌥E` shows an encouragement toast when the backend is reachable.
  - `⌃⌥W` requests microphone permission, records, stops, and copies the backend result to the clipboard; `Escape` cancels recording.
  - `⌃⌥R` requests Screen Recording permission, captures a selected region, and copies extracted text to the clipboard; `Escape` cancels capture.
  - Missing token, denied permissions, backend errors, and shortcut conflicts produce an error toast rather than a crash.

- [ ] Confirm temporary audio and screenshot files are removed after success, cancellation, and failure by inspecting the temporary directory after exercising the voice and screenshot flows.

- [ ] Confirm telemetry is written under the app support directory, is not required for feature success, and does not contain raw payloads unless **Store raw LLM text in telemetry** is enabled.

## Final sign-off

- [ ] Backend build passes.
- [ ] Backend tests pass.
- [ ] Backend authenticated and unauthenticated smoke checks pass.
- [ ] Swift app build passes.
- [ ] Swift tests pass.
- [ ] Architecture checks pass with no unexpected provider, secret, target, or boundary violations.
- [ ] Runtime checks pass, or skipped manual checks are explicitly documented.
- [ ] Final diff has been reviewed for unrelated changes and accidental secrets.
