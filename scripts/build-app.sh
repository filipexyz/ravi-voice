#!/usr/bin/env bash
# Builds a release binary and wraps it in build/RaviVoice.app, signed so macOS keeps the
# microphone / Input Monitoring grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/RaviVoice.app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/RaviVoice"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RaviVoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps TCC grants; ad-hoc signatures change every build.
IDENTITY="${RAVI_VOICE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: no signing identity found; using ad-hoc (permissions reset on every build)" >&2
  codesign --force --sign - "$APP"
fi
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"
