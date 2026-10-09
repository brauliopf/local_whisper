#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
agent_dir="$repo_root/browser-agent"
out_dir="${1:-$repo_root/build/browser-agent}"

rm -rf "$out_dir"
mkdir -p "$out_dir"

cd "$agent_dir"
npm ci
npm run build
npx playwright install chromium

cp -R dist package.json package-lock.json node_modules "$out_dir/"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  while IFS= read -r executable; do
    codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" "$executable"
  done < <(find "$out_dir" -type f \( -perm -111 -o -name 'node' \))
fi

echo "Packaged browser agent at $out_dir"
