#!/bin/bash
# 🐶 Datadog Assistant — installer for macOS
# Sets up a venv, installs rumps, optionally stores keys in the Keychain,
# and installs a LaunchAgent so the app starts at login.
set -euo pipefail

APP_DIR="$HOME/.datadog-assistant"
CONFIG_DIR="$HOME/.config/datadog-assistant"
PLIST="$HOME/Library/LaunchAgents/com.nour.datadog-assistant.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🐶 Installing Datadog Assistant..."

# 1. App files + venv
mkdir -p "$APP_DIR" "$CONFIG_DIR"
cp "$SRC_DIR/datadog_assistant.py" "$APP_DIR/"
if [ ! -d "$APP_DIR/venv" ]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip rumps
echo "✅ Python environment ready"

# 2. Keys → macOS Keychain (recommended; skips if already present)
read -r -p "🔐 Store your Datadog keys in the macOS Keychain now? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  read -r -s -p "   Datadog API key: " API_KEY; echo
  read -r -s -p "   Datadog APP key: " APP_KEY; echo
  security add-generic-password -U -s datadog-assistant-api-key -a "$USER" -w "$API_KEY"
  security add-generic-password -U -s datadog-assistant-app-key -a "$USER" -w "$APP_KEY"
  # flip use_keychain=true in config
  python3 - "$CONFIG_DIR/config.json" <<'EOF'
import json, sys, os
p = sys.argv[1]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["use_keychain"] = True
json.dump(cfg, open(p, "w"), indent=2)
EOF
  echo "✅ Keys stored in Keychain"
else
  echo "ℹ️  OK — put your keys in $CONFIG_DIR/config.json (api_key / app_key)"
fi

# 3. LaunchAgent (start at login, keep alive)
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nour.datadog-assistant</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/venv/bin/python3</string>
    <string>$APP_DIR/datadog_assistant.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$APP_DIR/stderr.log</string>
  <key>StandardOutPath</key><string>$APP_DIR/stdout.log</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "✅ LaunchAgent installed — starts at login"

echo ""
echo "🎉 Done! Look for 🐶 in your menu bar."
echo "   Config:  $CONFIG_DIR/config.json"
echo "   Logs:    $APP_DIR/stderr.log"
