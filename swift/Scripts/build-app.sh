#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it into a proper .app bundle so it
# can register as an LSUIElement (menu-bar-only) app. Run from swift/.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Datadog Assistant"
APP_DIR="build/${APP_NAME}.app"
EXECUTABLE_NAME="DatadogAssistant"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${EXECUTABLE_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Stamp the real version into the bundle (VERSION env from the release
# workflow's tag, else the latest tag for local builds) — otherwise every
# release ships an app that reports the placeholder version.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
if [[ -n "${VERSION}" ]]; then
    echo "==> stamping version ${VERSION}"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString ${VERSION}" \
        -c "Set :CFBundleVersion ${VERSION}" \
        "${APP_DIR}/Contents/Info.plist"
fi

# Ad-hoc sign by default so TCC (notifications) has a stable code identity
# across rebuilds; ./Scripts/notarize.sh does the real Developer ID signing.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "==> codesign (ad-hoc; set SIGN_IDENTITY or run notarize.sh for release)"
    codesign --force --deep --sign - "${APP_DIR}"
fi

echo "==> done: ${APP_DIR}"
echo "    open \"${APP_DIR}\"   # to launch"
