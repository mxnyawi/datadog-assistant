#!/bin/bash
# Build the double-clickable installer .app. RUN THIS ON A MAC.
# It bundles datadog_assistant.py so the installer is self-contained.
set -euo pipefail
cd "$(dirname "$0")"

echo "🐶 Building 'Datadog Assistant Installer.app'..."
python3 -m pip install --quiet --upgrade pyinstaller

pyinstaller --noconfirm --clean --windowed \
  --name "Datadog Assistant Installer" \
  --osx-bundle-identifier com.nour.datadog-assistant-installer \
  --add-data "../datadog_assistant.py:." \
  install_gui.py

APP="dist/Datadog Assistant Installer.app"
echo ""
echo "✅ Built: installer/$APP"
echo ""
echo "Zip it for distribution (attach to a GitHub Release):"
echo "   ditto -c -k --keepParent \"$APP\" \"Datadog-Assistant-Installer.zip\""
echo ""
echo "Note: it is unsigned, so the first launch needs right-click → Open."
