#!/bin/bash
# Builds a signed, notarized Loadline DMG into ./build and optionally publishes it.
# Usage: ./release.sh [--publish]
# Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist first:
# Sparkle compares CFBundleVersion to decide whether an update is newer.
# One-time setup:
#   xcrun notarytool store-credentials loadline-notary \
#     --apple-id <apple-id> --team-id Z2JK3QC3SS --password <app-specific-password>
#   The Sparkle EdDSA private key must be in the login keychain (generate_keys; its public
#   key is SUPublicEDKey in Info.plist).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Developer ID Application: Donghyeok Kim (Z2JK3QC3SS)"
NOTARY_PROFILE="loadline-notary"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/Loadline-$VERSION.dmg"

SIGN_IDENTITY="$IDENTITY" UNIVERSAL=1 ./build.sh release
codesign --verify --strict --verbose=2 build/Loadline.app

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Loadline.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Loadline" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

# The app's feed is releases/latest/download/appcast.xml, so every release carries an appcast
# listing just itself. generate_appcast signs the DMG with the EdDSA key from the keychain.
APPCAST_DIR="build/appcast"
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$APPCAST_DIR" \
    --download-url-prefix "https://github.com/eastLight210/Loadline/releases/download/v$VERSION/" \
    --link "https://github.com/eastLight210/Loadline"
echo "Ready: $DMG, $APPCAST_DIR/appcast.xml"

if [[ "${1:-}" == "--publish" ]]; then
    gh release create "v$VERSION" "$DMG" "$APPCAST_DIR/appcast.xml" --title "Loadline $VERSION" --generate-notes
fi
