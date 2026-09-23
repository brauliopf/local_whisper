#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d)"
RESULT_BUNDLE="$(mktemp -d)/computer-use.xcresult"
trap 'rm -rf "$DERIVED_DATA" "${RESULT_BUNDLE%/*}"' EXIT

API_KEY="${OPENAI_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  API_KEY="$(security find-generic-password -s brauliopf.local-whisper -a openai-api-key -w 2>/dev/null || true)"
fi
if [[ -z "$API_KEY" ]]; then
  echo "No OpenAI API key found. Set OPENAI_API_KEY or save one in local_whisper Settings." >&2
  exit 1
fi

URL="${COMPUTER_USE_TEST_URL:-https://en.wikipedia.org/wiki/Playwright}"
TASK="${COMPUTER_USE_TEST_TASK:-Read the page title and summarize the first paragraph in a generic table.}"

xcodebuild \
  -scheme local_whisper \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build-for-testing \
  CODE_SIGNING_ALLOWED=NO

XCTESTRUN="$(find "$DERIVED_DATA" -name '*.xctestrun' -print -quit)"

set_test_env() {
  local name="$1" value="$2"
  plutil -insert "TestConfigurations.0.TestTargets.0.EnvironmentVariables.$name" \
    -string "$value" "$XCTESTRUN" 2>/dev/null || \
  plutil -replace "TestConfigurations.0.TestTargets.0.EnvironmentVariables.$name" \
    -string "$value" "$XCTESTRUN"
}

set_test_env OPENAI_API_KEY "$API_KEY"
set_test_env LOCAL_WHISPER_NODE "$(command -v node)"
set_test_env LOCAL_WHISPER_EXECUTOR "$ROOT/computer-use-executor/dist/index.js"
set_test_env COMPUTER_USE_TEST_URL "$URL"
set_test_env COMPUTER_USE_TEST_TASK "$TASK"
set_test_env COMPUTER_USE_OUTPUT_PATH "${RESULT_BUNDLE%/*}/computer-use-result.txt"

set +e
xcodebuild \
  test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination 'platform=macOS' \
  -only-testing:local_whisperTests/ComputerUseLiveIntegrationTests \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO
status=$?
set -e

if [[ -f "${RESULT_BUNDLE%/*}/computer-use-result.txt" ]]; then
  echo
  echo '--- Computer-use result ---'
  cat "${RESULT_BUNDLE%/*}/computer-use-result.txt"
  echo '--- End result ---'
fi

exit "$status"
