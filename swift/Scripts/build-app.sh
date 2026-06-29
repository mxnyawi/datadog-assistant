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

echo "==> done: ${APP_DIR}"
echo "    open \"${APP_DIR}\"   # to launch"
