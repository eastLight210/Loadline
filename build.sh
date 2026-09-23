#!/bin/bash
# Builds Loadline.app into ./build. Usage: ./build.sh [release|debug] [--run]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Loadline"

APP="build/Loadline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loadline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x Loadline 2>/dev/null || true
    open "$APP"
fi
