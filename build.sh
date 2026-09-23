#!/bin/bash
# Builds Loadline.app into ./build. Usage: ./build.sh [release|debug] [--run]
# Env: SIGN_IDENTITY (default "-" = ad-hoc), UNIVERSAL=1 to build arm64 + x86_64.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Loadline"

APP="build/Loadline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loadline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP" >/dev/null
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x Loadline 2>/dev/null || true
    open "$APP"
fi
