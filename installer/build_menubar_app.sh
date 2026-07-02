#!/bin/bash
# Build "Datadog Assistant.app" — the single self-onboarding bundle. RUN ON A MAC.
#
# Compiles the app with py2app so that:
#   - first launch (no config) shows the onboarding GUI, then it runs as the
#     menu-bar app — one bundle, two modes,
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

# Pick a Python the native stack is happy with. py2app + pyobjc + rumps +
# pywebview lag the newest CPython by a release or two; building on 3.13/3.14
# yields a bundle that crashes at startup ("dlsym cannot find symbol NSMakeRect
# … principal class is nil"). Prefer 3.12 → 3.11 → 3.10.
pick_python() {
  for p in python3.12 python3.11 python3.10; do
    command -v "$p" >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo "python3"  # last resort; warned about below
}
PY="$(pick_python)"
PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
case "$PYVER" in
  3.10|3.11|3.12) ;;
  *)
    echo "❌ Building with Python $PYVER. The native deps (pyobjc/rumps/py2app/"
    echo "   pywebview) are unreliable on 3.13+ and the bundle is known to crash"
    echo "   at launch — refusing to build a knowingly-broken app that release.sh"
    echo "   would happily publish. Install a supported one and re-run:"
    echo "       brew install python@3.12"
    echo "   (override at your own risk: DD_ALLOW_UNSUPPORTED_PY=1)"
    if [ "${DD_ALLOW_UNSUPPORTED_PY:-}" != "1" ]; then
      exit 1
    fi ;;
esac
echo "🐍 Using $PY (Python $PYVER)"

# Build inside an isolated venv so we never hit PEP 668 'externally-managed'.
# Recreate it if it was made with a different Python.
BV=".build-venv"
if [ -d "$BV" ] && ! "$BV/bin/python" -c "import sys; assert '%d.%d'%sys.version_info[:2]=='$PYVER'" 2>/dev/null; then
  echo "   (rebuilding $BV for Python $PYVER)"
  rm -rf "$BV"
fi
[ -d "$BV" ] || "$PY" -m venv "$BV"
# py2app pinned to a known-good minor: an unpinned latest broke release
# builds before with no code change in this repo.
"$BV/bin/pip" install --quiet --upgrade pip "py2app>=0.28,<0.29" -r requirements.txt

echo "🐶 Building 'Datadog Assistant.app' with py2app ..."
rm -rf build dist
"$BV/bin/python" setup.py py2app

echo ""
echo "✅ Built: dist/Datadog Assistant.app"
echo "   Try it:   open 'dist/Datadog Assistant.app'"
echo "   Notification clicks now open the monitor in Datadog."
echo "   First launch on a fresh download: right-click → Open (it's unsigned)."
