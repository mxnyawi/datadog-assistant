#!/bin/bash
# Build the native installer into a double-clickable .app , RUN ON A MAC.
# Uses osacompile (built into macOS): no pip, no Tk, no PyInstaller.
set -euo pipefail
cd "$(dirname "$0")"

APP="Datadog Assistant Installer.app"
echo "🐶 Building '$APP' with osacompile..."
rm -rf "$APP"
osacompile -o "$APP" install.applescript

# bundle the engine + the app source so the .app is self-contained
cp do_install.sh "$APP/Contents/Resources/do_install.sh"
cp ../datadog_assistant.py "$APP/Contents/Resources/datadog_assistant.py"
chmod +x "$APP/Contents/Resources/do_install.sh"

echo ""
echo "✅ Built: installer/$APP"
echo "   Double-click it to run. First launch: right-click → Open (it's unsigned)."
echo ""
echo "Zip it for a GitHub Release:"
echo "   ditto -c -k --keepParent \"$APP\" \"Datadog-Assistant-Installer.zip\""
