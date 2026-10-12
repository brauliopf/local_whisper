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
rm -f "$runtime_dir"/*.dylib
cp -R "$sidecar_dir/dist" "$runtime_dir/dist"
cp -R "$sidecar_dir/node_modules" "$runtime_dir/node_modules"
cp "$node_binary" "$runtime_dir/node"
chmod +x "$runtime_dir/node"

# Homebrew's Node executable is dynamically linked. Bundle its non-system
# libraries and rewrite references so the app does not depend on Homebrew.
bundle_dependency() (
  source_binary="$1"
  target_binary="$2"
  otool -L "$source_binary" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/*) continue ;;
    esac
    dependency_name=$(basename "$dependency")
    resolved="$dependency"
    case "$dependency" in
      @loader_path/*)
        resolved="$(dirname "$source_binary")/${dependency#@loader_path/}"
        ;;
      @rpath/*)
        resolved="$(dirname "$node_binary")/../lib/$dependency_name"
        ;;
      /*)
        ;;
      *)
        resolved="$(dirname "$node_binary")/../lib/$dependency_name"
        ;;
    esac
    if [ ! -f "$resolved" ]; then
      resolved="$(dirname "$node_binary")/../lib/$dependency_name"
    fi
    if [ ! -f "$resolved" ]; then
      resolved="$(dirname "$node_binary")/../Cellar/*/lib/$dependency_name"
    fi
    for candidate in $resolved /opt/homebrew/lib/$dependency_name /usr/local/lib/$dependency_name; do
      if [ -f "$candidate" ]; then
        resolved="$candidate"
        break
      fi
    done
    if [ ! -f "$resolved" ]; then
      echo "Unable to bundle Node dependency: $dependency" >&2
      exit 1
    fi
    bundled="$runtime_dir/$dependency_name"
    if [ ! -f "$bundled" ]; then
      cp "$resolved" "$bundled"
      chmod +x "$bundled"
      bundle_dependency "$resolved" "$bundled"
    fi
    install_name_tool -change "$dependency" "@loader_path/$dependency_name" "$target_binary"
  done
)

bundle_dependency "$node_binary" "$runtime_dir/node"
cp "$sidecar_dir/bin/browser-sidecar" "$output_dir/browser-sidecar"
chmod +x "$output_dir/browser-sidecar"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
  for library in "$runtime_dir"/*.dylib; do
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$library"
  done
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$runtime_dir/node"
fi
