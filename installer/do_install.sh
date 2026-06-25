#!/bin/bash
# Non-interactive install engine for Datadog Assistant.
# Driven by env vars so the GUI installers (and tests) can call it.
# Mirrors ../install.sh. Safe to re-run.
#
#   DD_SRC            path to datadog_assistant.py to install   (required)
#   DD_SITE           datadoghq.com | datadoghq.eu | ...        (default us)
#   DD_AUTH           keys | oauth                               (default keys)
#   DD_API_KEY        Datadog API key   (keys mode)
#   DD_APP_KEY        Datadog Application key   (keys mode)
#   DD_OAUTH_CLIENT_ID  OAuth client id   (oauth mode)
#   DD_TAG_FILTER     optional "team:payments env:prod"
#   DD_SUBDOMAIN      optional company subdomain
#   DD_DRY_RUN        1 = skip venv/pip/keychain/launchctl (for tests)
set -euo pipefail

# config.json may hold credentials, so create everything owner-only.
umask 077

APP_DIR="$HOME/.datadog-assistant"
CONFIG_DIR="$HOME/.config/datadog-assistant"
CONFIG="$CONFIG_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/com.nour.datadog-assistant.plist"

DD_SITE="${DD_SITE:-datadoghq.com}"
DD_AUTH="${DD_AUTH:-keys}"
DD_DRY_RUN="${DD_DRY_RUN:-0}"
: "${DD_SRC:?DD_SRC (path to datadog_assistant.py) is required}"

say() { echo "→ $1"; }

say "Creating folders"
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$(dirname "$PLIST")"

say "Copying the app"
cp "$DD_SRC" "$APP_DIR/datadog_assistant.py"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "ERROR: python3 not found. Open Terminal, run 'xcode-select --install', then retry." >&2
  exit 1
fi

if [ "$DD_DRY_RUN" != "1" ]; then
  if [ ! -d "$APP_DIR/venv" ]; then
    say "Creating a Python environment"
    "$PY" -m venv "$APP_DIR/venv"
  fi
  say "Installing rumps"
  "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip rumps
fi

say "Writing settings"
DD_SITE="$DD_SITE" DD_AUTH="$DD_AUTH" \
DD_OAUTH_CLIENT_ID="${DD_OAUTH_CLIENT_ID:-}" \
DD_TAG_FILTER="${DD_TAG_FILTER:-}" DD_SUBDOMAIN="${DD_SUBDOMAIN:-}" \
"$PY" - "$CONFIG" <<'PYEOF'
import json, os, sys
p = sys.argv[1]
cfg = {}
if os.path.exists(p):
    try:
        cfg = json.load(open(p))
    except Exception:
        cfg = {}
cfg["site"] = os.environ["DD_SITE"]
cfg["app_subdomain"] = os.environ.get("DD_SUBDOMAIN") or "app"
cfg["tag_filter"] = os.environ.get("DD_TAG_FILTER", "")
if os.environ["DD_AUTH"] == "oauth":
    cfg["auth"] = "oauth"
    cfg["oauth_client_id"] = os.environ.get("DD_OAUTH_CLIENT_ID", "")
else:
    cfg["auth"] = "keys"
    cfg["use_keychain"] = True
json.dump(cfg, open(p, "w"), indent=2)
PYEOF

if [ "$DD_AUTH" = "keys" ] && [ "$DD_DRY_RUN" != "1" ]; then
  say "Storing keys in the Keychain"
  [ -n "${DD_API_KEY:-}" ] && security add-generic-password -U \
    -s datadog-assistant-api-key -a "$USER" -w "$DD_API_KEY"
  [ -n "${DD_APP_KEY:-}" ] && security add-generic-password -U \
    -s datadog-assistant-app-key -a "$USER" -w "$DD_APP_KEY"
fi

say "Installing the login item"
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
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$APP_DIR/stderr.log</string>
  <key>StandardOutPath</key><string>$APP_DIR/stdout.log</string>
</dict>
</plist>
EOF

if [ "$DD_DRY_RUN" != "1" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
fi
say "Done"
