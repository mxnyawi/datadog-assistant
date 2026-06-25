#!/bin/bash
# Build the *running* menu-bar app into a real "Datadog Assistant.app". RUN ON A MAC.
#
# Unlike build_app.sh / build.sh (which package the one-shot *installer*), this
# compiles the app itself with py2app so that:
#   - notification clicks open the Datadog monitor (a bundle id is required for
#     macOS to route the click — a bare script can't),
#   - it shows its own name + icon instead of "Python",
#   - it's a self-contained .app you can drag to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

PNG="website/assets/icon.png"
ICON="installer/icon.icns"

# Generate installer/icon.icns from the website PNG (once), if tools are around.
if [ -f "$PNG" ] && [ ! -f "$ICON" ] && command -v iconutil >/dev/null 2>&1; then
  echo "🎨 Generating $ICON from $PNG ..."
  SET="$(mktemp -d)/icon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             "$PNG" --out "$SET/icon_${s}x${s}.png"     >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$PNG" --out "$SET/icon_${s}x${s}@2x.png"  >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON" \
    || echo "  (icon build failed — continuing without an icon)"
fi

# Build inside an isolated venv so we never hit PEP 668 'externally-managed'.
BV=".build-venv"
[ -d "$BV" ] || python3 -m venv "$BV"
"$BV/bin/pip" install --quiet --upgrade pip py2app -r requirements.txt

echo "🐶 Building 'Datadog Assistant.app' with py2app ..."
rm -rf build dist
"$BV/bin/python" setup.py py2app

echo ""
echo "✅ Built: dist/Datadog Assistant.app"
echo "   Try it:   open 'dist/Datadog Assistant.app'"
echo "   Notification clicks now open the monitor in Datadog."
echo "   First launch on a fresh download: right-click → Open (it's unsigned)."
