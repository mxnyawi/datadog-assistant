#!/usr/bin/env bash
# Sign, notarize, and staple the .app produced by build-app.sh.
#
# Required env:
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE  keychain profile created via:
#                   xcrun notarytool store-credentials <profile> \
#                     --apple-id you@example.com --team-id TEAMID
#
# Usage: ./Scripts/notarize.sh   (after ./Scripts/build-app.sh)
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Datadog Assistant.app"
ZIP="build/Datadog-Assistant.zip"
ENTITLEMENTS="Resources/DatadogAssistant.entitlements"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./Scripts/build-app.sh first" >&2; exit 1; }

echo "==> codesign (hardened runtime)"
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> zip for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarytool submit (waits for Apple)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> re-zip stapled app for distribution"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

echo "==> done: $ZIP (+ .sha256)"
