#!/usr/bin/env bash

# Automated portion of clean-state-checklist.md.
# Run from the repository root: bash scripts/clean_state_check.sh

set -u

root_dir=$(cd "$(dirname "$0")/.." && pwd)
failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

run_check() {
  local name=$1
  shift
  printf '\nCHECK %s\n' "$name"
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

contains() {
  local pattern=$1
  local file=$2
  grep -Eq "$pattern" "$file"
}

backend_dir="$root_dir/backend"
project_file="$root_dir/local_whisper.xcodeproj"

printf 'Clean-state validation\nRepository: %s\n' "$root_dir"

run_check "backend tests" bash -c "cd '$backend_dir' && npm test"

run_check "backend source and generated output are present" bash -c "
  test -f '$backend_dir/src/server.ts' &&
  test -f '$backend_dir/src/app.ts' &&
  test -f '$backend_dir/dist/server.js' &&
  test -f '$backend_dir/dist/app.js'
"

run_check "backend composition boundaries" bash -c "
  grep -Eq 'loadConfig' '$backend_dir/src/server.ts' &&
  grep -Eq 'buildApp' '$backend_dir/src/server.ts' &&
  grep -Eq 'BackendProvider' '$backend_dir/src/provider.ts' &&
  grep -Eq 'TranscriptionWorkflow' '$backend_dir/src/transcription.ts'
"

run_check "backend API and client contract" bash -c "
  grep -Fq '/status' '$backend_dir/src/app.ts' &&
  grep -Fq '/image-text' '$backend_dir/src/app.ts' &&
  grep -Fq '/encouragements' '$backend_dir/src/app.ts' &&
  grep -Fq '/transcriptions' '$backend_dir/src/app.ts' &&
  grep -Fq 'fieldName:' '$root_dir/local_whisper/Shared/Backend/BackendClient.swift' &&
  grep -Fq 'image' '$root_dir/local_whisper/Shared/Backend/BackendClient.swift' &&
  grep -Fq 'audio' '$root_dir/local_whisper/Shared/Backend/BackendClient.swift'
"

run_check "backend does not contain provider credentials" bash -c "
  ! grep -REq 'sk-[A-Za-z0-9]' '$backend_dir/src'
"

if ! smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/local-whisper-clean-state.XXXXXX"); then
  fail "backend smoke workspace (mktemp failed; runtime checks cannot run)"
  printf '\nCLEAN STATE: FAIL (%d check(s))\n' "$failures" >&2
  exit 1
fi

backend_log="$smoke_dir/backend.log"
backend_status="$smoke_dir/status.json"
backend_pid=''

cleanup() {
  if [ -n "$backend_pid" ]; then
    kill "$backend_pid" 2>/dev/null || true
    wait "$backend_pid" 2>/dev/null || true
  fi
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

run_check "backend status smoke test" bash -c "
  cd '$backend_dir'
  PORT=18080 OPENAI_API_KEY=test-openai-key SERVICE_TOKEN=test-service-token \
    node dist/server.js > '$backend_log' 2>&1 &
  pid=\$!
  for attempt in \$(seq 1 20); do
    if curl --silent --fail http://127.0.0.1:18080/status > '$backend_status'; then
      break
    fi
    sleep 0.25
  done
  kill \$pid 2>/dev/null || true
  wait \$pid 2>/dev/null || true
  grep -q '\"status\":\"ok\"' '$backend_status' &&
    grep -q '\"openai\":{\"configured\":true}' '$backend_status'
"

run_check "backend authentication smoke test" bash -c "
  cd '$backend_dir'
  PORT=18081 OPENAI_API_KEY=test-openai-key SERVICE_TOKEN=test-service-token \
    node dist/server.js > '$backend_log' 2>&1 &
  pid=\$!
  for attempt in \$(seq 1 20); do
    curl --silent http://127.0.0.1:18081/status >/dev/null && break
    sleep 0.25
  done
  unauthorized=\$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18081/encouragements \
    -H 'Content-Type: application/json' -d '{}')
  wrong_token=\$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18081/encouragements \
    -H 'Authorization: Bearer wrong-token' \
    -H 'Content-Type: application/json' -d '{}')
  accepted_token=\$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST http://127.0.0.1:18081/encouragements \
    -H 'Authorization: Bearer test-service-token' \
    -H 'Content-Type: application/json' -d '{\"unexpected\":true}')
  kill \$pid 2>/dev/null || true
  wait \$pid 2>/dev/null || true
  test \"\$unauthorized\" = 401 &&
    test \"\$wrong_token\" = 401 &&
    test \"\$accepted_token\" = 400
"

run_check "Swift project and synchronized targets" bash -c "
  test -d '$project_file' &&
  grep -Eq 'PBXFileSystemSynchronizedRootGroup' '$project_file/project.pbxproj' &&
  grep -Eq 'local_whisperTests' '$project_file/project.pbxproj' &&
  test -f '$root_dir/local_whisperTests/CountdownTests.swift' &&
  test -f '$root_dir/local_whisperTests/TimerSettingsTests.swift'
"

run_check "Swift architecture boundaries" bash -c "
  grep -Eq '@main|NSApplicationDelegateAdaptor' '$root_dir/local_whisper/App/local_whisperApp.swift' &&
  grep -Eq 'RegisterEventHotKey' '$root_dir/local_whisper/Shared/Hotkeys.swift' &&
  grep -Eq 'BackendClient' '$root_dir/local_whisper/Shared/Backend/BackendClient.swift' &&
  ! grep -REq 'sk-[A-Za-z0-9]|api\\.openai\\.com' '$root_dir/local_whisper'
"

run_check "Swift build and tests" xcodebuild \
  -project "$project_file" \
  -scheme local_whisper \
  -destination 'platform=macOS' \
  test

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'CLEAN STATE: PASS\n'
  exit 0
fi

printf 'CLEAN STATE: FAIL (%d check(s))\n' "$failures" >&2
printf 'Review the first failing check output, fix the reported boundary or behavior, and rerun this script.\n' >&2
exit 1
