#!/bin/bash
# Build the Tkinter installer into a .app (RUN ON A MAC).
# Most people should use build_app.sh instead , the native AppleScript installer
# needs no Python, Tk, or pip. Use this only if you want the single-window UI.
set -euo pipefail
cd "$(dirname "$0")"

# PyInstaller needs a python3 that HAS tkinter (the built .app bundles Tk, so
# end users won't need it , this is a build-time requirement only).
if ! python3 -c "import tkinter" >/dev/null 2>&1; then
  cat >&2 <<'MSG'
✗ Your python3 has no Tk, so the single-window installer can't be built with it.
  Install a Tk-capable Python, then retry:
      brew install python-tk          (matches Homebrew's python3)
  or install Python from python.org   (bundles Tcl/Tk)

  Tip: you don't need any of this for the native installer , just run
      ./installer/build_app.sh
MSG
  exit 1
fi

# Build inside an isolated venv so we never hit PEP 668 'externally-managed'.
echo "🐶 Building 'Datadog Assistant Installer.app' (Tkinter)..."
BV=".build-venv"
[ -d "$BV" ] || python3 -m venv "$BV"
"$BV/bin/pip" install --quiet --upgrade pip pyinstaller

"$BV/bin/pyinstaller" --noconfirm --clean --windowed \
  --name "Datadog Assistant Installer" \
  --osx-bundle-identifier com.nour.datadog-assistant-installer \
  --add-data "../datadog_assistant.py:." \
  install_gui.py

APP="dist/Datadog Assistant Installer.app"
echo ""
echo "✅ Built: installer/$APP"
echo "   First launch: right-click → Open (it's unsigned)."
echo ""
echo "Zip it for a GitHub Release:"
echo "   ditto -c -k --keepParent \"$APP\" \"Datadog-Assistant-Installer.zip\""
