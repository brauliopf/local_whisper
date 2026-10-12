#!/bin/sh
set -eu

sidecar_dir="${PROJECT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}/browser-sidecar"
output_dir="${TARGET_BUILD_DIR:-$sidecar_dir/.build}/$CONTENTS_FOLDER_PATH/Resources"
runtime_dir="$output_dir/browser-sidecar-runtime"
node_binary="${NODE_BINARY:-$(command -v node || true)}"

if [ -z "$node_binary" ] || [ ! -x "$node_binary" ]; then
  echo "A Node.js executable is required to package the browser sidecar." >&2
  exit 1
fi

if [ ! -d "$sidecar_dir/node_modules" ]; then
  npm --prefix "$sidecar_dir" ci
fi
if [ ! -d "$sidecar_dir/node_modules/playwright-core/.local-browsers/chromium-1248" ]; then
  PLAYWRIGHT_BROWSERS_PATH=0 npm --prefix "$sidecar_dir" exec -- playwright install chromium
fi
npm --prefix "$sidecar_dir" run build

mkdir -p "$runtime_dir" "$output_dir"
rm -rf "$runtime_dir/dist" "$runtime_dir/node_modules" "$runtime_dir/node" "$output_dir/browser-sidecar"
cp -R "$sidecar_dir/dist" "$runtime_dir/dist"
cp -R "$sidecar_dir/node_modules" "$runtime_dir/node_modules"
cp "$node_binary" "$runtime_dir/node"
chmod +x "$runtime_dir/node"
cp "$sidecar_dir/bin/browser-sidecar" "$output_dir/browser-sidecar"
chmod +x "$output_dir/browser-sidecar"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$runtime_dir/node"
fi
