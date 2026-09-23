#!/bin/bash
# Builds a signed, notarized Loadline DMG into ./build and optionally publishes it.
# Usage: ./release.sh [--publish]
# One-time setup:
#   xcrun notarytool store-credentials loadline-notary \
#     --apple-id <apple-id> --team-id Z2JK3QC3SS --password <app-specific-password>
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
echo "Ready: $DMG"

if [[ "${1:-}" == "--publish" ]]; then
    gh release create "v$VERSION" "$DMG" --title "Loadline $VERSION" --generate-notes
fi
