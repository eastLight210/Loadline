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
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Loadline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Loadline" "$APP/Contents/MacOS/Loadline"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 15.0 --target-device mac \
    --output-partial-info-plist "$(mktemp)" >/dev/null
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN=(codesign --force --sign -)
else
    SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
# Sign Sparkle's nested code inside-out, then the app (no --deep).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc" >/dev/null
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc" >/dev/null
"${SIGN[@]}" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" >/dev/null
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
"${SIGN[@]}" "$APP" >/dev/null
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x Loadline 2>/dev/null || true
    open "$APP"
fi
