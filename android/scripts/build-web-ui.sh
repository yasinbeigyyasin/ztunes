#!/usr/bin/env bash
# Build the full SvelteKit UI for Android's local WebView bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if command -v pnpm >/dev/null; then
  PM=(pnpm)
elif command -v corepack >/dev/null; then
  PM=(corepack pnpm)
else
  echo 'Install Node.js and pnpm (or Corepack) before building the Android WebView UI.' >&2
  exit 1
fi
cd "$ROOT/ui"
"${PM[@]}" install --frozen-lockfile
ZTUNES_ANDROID_WEBVIEW=1 "${PM[@]}" run test
ZTUNES_ANDROID_WEBVIEW=1 "${PM[@]}" run check
ZTUNES_ANDROID_WEBVIEW=1 "${PM[@]}" run build
test -f "$ROOT/ui/build/index.html" || { echo 'SvelteKit did not produce ui/build/index.html' >&2; exit 1; }
echo "Android WebView UI built in $ROOT/ui/build"
