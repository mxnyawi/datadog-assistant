#!/bin/bash
# 🐶 Datadog Assistant — installer for macOS
# Sets up a venv, installs rumps, optionally stores keys in the Keychain,
# and installs a LaunchAgent so the app starts at login.
#
# Interactive by default. For unattended / agent / CI installs set
# DD_NONINTERACTIVE=1 (also auto-enabled when stdin isn't a terminal) and pass
# settings via environment variables — see AGENTS.md. Quick example:
#
#   DD_NONINTERACTIVE=1 DD_SITE=datadoghq.eu DD_APP_SUBDOMAIN=acme \
#   DD_TAG_FILTER="team:payments" DD_API_KEY=… DD_APP_KEY=… ./install.sh
#
set -euo pipefail

APP_DIR="$HOME/.datadog-assistant"
CONFIG_DIR="$HOME/.config/datadog-assistant"
PLIST="$HOME/Library/LaunchAgents/com.nour.datadog-assistant.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Unattended when DD_NONINTERACTIVE=1, or when stdin isn't a terminal
# (pipes / CI / agents). In unattended mode we never call `read`; every setting
# comes from an environment variable or falls back to a safe default.
NONINTERACTIVE="${DD_NONINTERACTIVE:-}"
[ -t 0 ] || NONINTERACTIVE=1
[ -n "$NONINTERACTIVE" ] && echo "🤖 Unattended install — reading settings from the environment (see AGENTS.md)"

# write_config KEY VALUE — merge one string key into config.json
write_config() {
  python3 - "$CONFIG_DIR/config.json" "$1" "$2" <<'EOF'
import json, sys, os
p, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg[key] = val
json.dump(cfg, open(p, "w"), indent=2)
EOF
}

# mark_keychain_keys — auth=keys + use_keychain=true (keys live in the Keychain)
mark_keychain_keys() {
  python3 - "$CONFIG_DIR/config.json" <<'EOF'
import json, sys, os
p = sys.argv[1]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["auth"] = "keys"
cfg["use_keychain"] = True
json.dump(cfg, open(p, "w"), indent=2)
EOF
}

echo "🐶 Installing Datadog Assistant..."

# 1. App files + venv
mkdir -p "$APP_DIR" "$CONFIG_DIR"
cp "$SRC_DIR/datadog_assistant.py" "$APP_DIR/"
if [ ! -d "$APP_DIR/venv" ]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip rumps
echo "✅ Python environment ready"

# 2. Datadog site/region (wrong region = 403 from the API)
if [ -n "${DD_SITE:-}" ]; then
  SITE="$DD_SITE"
elif [ -n "$NONINTERACTIVE" ]; then
  SITE="datadoghq.com"
else
  echo ""
  echo "🌐 Which Datadog site is your org on? (check your browser URL, e.g. app.datadoghq.eu)"
  echo "   1) US1  — datadoghq.com (app.datadoghq.com)"
  echo "   2) EU   — datadoghq.eu"
  echo "   3) US3  — us3.datadoghq.com"
  echo "   4) US5  — us5.datadoghq.com"
  echo "   5) AP1  — ap1.datadoghq.com"
  echo "   6) GOV  — ddog-gov.com"
  read -r -p "   Choice [1-6, default 1]: " region
  case "${region:-1}" in
    2) SITE="datadoghq.eu" ;;
    3) SITE="us3.datadoghq.com" ;;
    4) SITE="us5.datadoghq.com" ;;
    5) SITE="ap1.datadoghq.com" ;;
    6) SITE="ddog-gov.com" ;;
    *) SITE="datadoghq.com" ;;
  esac
fi
write_config site "$SITE"
echo "✅ Site set to $SITE"

# 2b. Custom company subdomain (links bounce to login without it)
if [ -n "${DD_APP_SUBDOMAIN:-}" ]; then
  SUBDOMAIN="$DD_APP_SUBDOMAIN"
elif [ -n "$NONINTERACTIVE" ]; then
  SUBDOMAIN=""
else
  echo ""
  echo "🏢 Does your org use a custom subdomain? (your browser shows"
  echo "   <company>.$SITE instead of app.$SITE)"
  read -r -p "   Company part (leave empty for app.$SITE): " SUBDOMAIN
fi
write_config app_subdomain "${SUBDOMAIN:-app}"
[ -n "$SUBDOMAIN" ] && echo "✅ Links will use $SUBDOMAIN.$SITE" || echo "ℹ️  Using app.$SITE"

# 3. Monitor tag filter (server-side — avoids downloading every monitor in the org)
if [ -n "${DD_TAG_FILTER:-}" ]; then
  TAGS="$DD_TAG_FILTER"
elif [ -n "$NONINTERACTIVE" ]; then
  TAGS=""
else
  echo ""
  echo "🏷  Filter monitors by tag? Only matching monitors are fetched and shown."
  echo "   Strongly recommended for large orgs. Space-separated, e.g.: team:payments env:prod"
  read -r -p "   Tags (leave empty for ALL monitors): " TAGS
fi
write_config tag_filter "$TAGS"
if [ -n "$TAGS" ]; then
  echo "✅ Tag filter set to: $TAGS"
else
  echo "ℹ️  No tag filter — fetching all monitors (you can set tag_filter in config.json later)"
fi

# 4. Authentication — API + App keys, or OAuth (browser login)
#    Env: DD_AUTH=keys|oauth ; keys from DD_API_KEY/DD_APP_KEY ;
#    oauth client from DD_OAUTH_CLIENT_ID.
if [ -n "${DD_AUTH:-}" ]; then
  AUTH="$DD_AUTH"
elif [ -n "$NONINTERACTIVE" ]; then
  AUTH="keys"
else
  echo ""
  echo "🔐 How do you want to authenticate to Datadog?"
  echo "   1) API + App keys  (quickest — paste them now, stored in the Keychain)"
  echo "   2) OAuth           (log in via the browser; needs a Datadog OAuth client)"
  read -r -p "   Choice [1-2, default 1]: " authm
  case "${authm:-1}" in 2) AUTH="oauth" ;; *) AUTH="keys" ;; esac
fi

if [ "$AUTH" = "oauth" ]; then
  if [ -n "${DD_OAUTH_CLIENT_ID:-}" ]; then
    DD_CLIENT_ID="$DD_OAUTH_CLIENT_ID"
  elif [ -n "$NONINTERACTIVE" ]; then
    DD_CLIENT_ID=""
  else
    echo ""
    echo "   OAuth needs a one-time OAuth client registered in Datadog"
    echo "   (Organization Settings → OAuth). Set its redirect URI to exactly:"
    echo "       http://localhost:8918/callback"
    echo "   and grant the scopes: monitors_read monitors_write monitors_downtime"
    echo "   dashboards_read incident_read metrics_read events_read"
    read -r -p "   Datadog OAuth Client ID: " DD_CLIENT_ID
  fi
  write_config auth oauth
  write_config oauth_client_id "$DD_CLIENT_ID"
  echo "✅ OAuth selected. After launch, click 🐶 → Preferences →"
  echo "   🔐 Datadog credentials → OAuth to finish the browser login."
else
  write_config auth keys
  if [ -n "${DD_API_KEY:-}" ] && [ -n "${DD_APP_KEY:-}" ]; then
    # Unattended: keys supplied via env go straight to the Keychain.
    security add-generic-password -U -s datadog-assistant-api-key -a "$USER" -w "$DD_API_KEY"
    security add-generic-password -U -s datadog-assistant-app-key -a "$USER" -w "$DD_APP_KEY"
    mark_keychain_keys
    echo "✅ Keys stored in Keychain"
  elif [ -n "$NONINTERACTIVE" ]; then
    echo "ℹ️  No DD_API_KEY/DD_APP_KEY provided. Add them later with:"
    echo "      security add-generic-password -U -s datadog-assistant-api-key -a \"\$USER\" -w 'API_KEY'"
    echo "      security add-generic-password -U -s datadog-assistant-app-key  -a \"\$USER\" -w 'APP_KEY'"
    echo "   then set \"use_keychain\": true in $CONFIG_DIR/config.json"
  else
    read -r -p "   Store your Datadog keys in the macOS Keychain now? [y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      read -r -s -p "   Datadog API key: " API_KEY; echo
      read -r -s -p "   Datadog APP key: " APP_KEY; echo
      security add-generic-password -U -s datadog-assistant-api-key -a "$USER" -w "$API_KEY"
      security add-generic-password -U -s datadog-assistant-app-key -a "$USER" -w "$APP_KEY"
      mark_keychain_keys
      echo "✅ Keys stored in Keychain"
    else
      echo "ℹ️  OK — put your keys in $CONFIG_DIR/config.json (api_key / app_key)"
    fi
  fi
fi

# 5. LaunchAgent (start at login, keep alive)
mkdir -p "$(dirname "$PLIST")"
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
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "✅ LaunchAgent installed — starts at login"

echo ""
echo "🎉 Done! Look for 🐶 in your menu bar."
echo "   Config:  $CONFIG_DIR/config.json"
echo "   Logs:    $APP_DIR/stderr.log"
