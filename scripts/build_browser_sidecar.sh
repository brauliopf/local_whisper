#!/bin/sh
set -eu

sidecar_dir="${PROJECT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}/browser-sidecar"
output_dir="${TARGET_BUILD_DIR:-$sidecar_dir/.build}/$CONTENTS_FOLDER_PATH/Resources"
runtime_dir="$output_dir/browser-sidecar-runtime"

if [ ! -d "$sidecar_dir/node_modules" ]; then
  npm --prefix "$sidecar_dir" ci
fi
if [ ! -d "$sidecar_dir/node_modules/playwright-core/.local-browsers/chromium-1248" ]; then
  PLAYWRIGHT_BROWSERS_PATH=0 npm --prefix "$sidecar_dir" exec -- playwright install chromium
fi
npm --prefix "$sidecar_dir" run build

mkdir -p "$runtime_dir" "$output_dir"
rm -rf "$runtime_dir/dist" "$runtime_dir/node_modules"
cp -R "$sidecar_dir/dist" "$runtime_dir/dist"
cp -R "$sidecar_dir/node_modules" "$runtime_dir/node_modules"
cp "$sidecar_dir/bin/browser-sidecar" "$output_dir/browser-sidecar"
chmod +x "$output_dir/browser-sidecar"
