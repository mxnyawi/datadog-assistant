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

# config.json may hold credentials (api_key/app_key or oauth_client_id), so
# everything this script creates should be owner-only.
umask 077

APP_DIR="$HOME/.datadog-assistant"
CONFIG_DIR="$HOME/.config/datadog-assistant"
PLIST="$HOME/Library/LaunchAgents/com.nour.datadog-assistant.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_TIMEOUT=""   # set by the LastPass auth path to seed the LaunchAgent env

# Unattended when DD_NONINTERACTIVE=1, or when stdin isn't a terminal
# (pipes / CI / agents). In unattended mode we never call `read`; every setting
# comes from an environment variable or falls back to a safe default.
NONINTERACTIVE="${DD_NONINTERACTIVE:-}"
if [ -n "$NONINTERACTIVE" ]; then
  echo "🤖 Unattended install — reading settings from the environment (see AGENTS.md)"
elif [ ! -t 0 ]; then
  # No TTY (e.g. 'curl … | bash'): we can't prompt, so we fall back to env vars
  # + defaults. Warn loudly so a human doesn't silently get site=datadoghq.com
  # and no keys when they expected the interactive wizard.
  NONINTERACTIVE=1
  echo "⚠️  No terminal detected (piped input, e.g. 'curl … | bash')."
  echo "   Running UNATTENDED with environment variables + defaults — no prompts,"
  echo "   no keys entered. For the interactive setup, download install.sh and run"
  echo "   it directly (./install.sh), or pass settings via env vars (see AGENTS.md)."
fi

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
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
# Install from the pinned requirements (avoids pulling an arbitrary latest
# rumps/pyobjc); fall back to a pinned spec if the file is somehow absent.
if [ -f "$SRC_DIR/requirements.txt" ]; then
  "$APP_DIR/venv/bin/pip" install --quiet -r "$SRC_DIR/requirements.txt"
else
  "$APP_DIR/venv/bin/pip" install --quiet 'rumps>=0.4.0,<0.5'
fi
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

# 4. Authentication — API + App keys, OAuth, or LastPass CLI
#    Env: DD_AUTH=keys|oauth|lastpass
#      keys     — DD_API_KEY / DD_APP_KEY (stored in the Keychain)
#      oauth    — DD_OAUTH_CLIENT_ID
#      lastpass — DD_LASTPASS_ENTRY (required), plus optional field overrides
#                 DD_LASTPASS_API_FIELD / _APP_FIELD / _JIRA_CID_FIELD /
#                 _JIRA_SEC_FIELD and DD_LPASS_AGENT_TIMEOUT.
if [ -n "${DD_AUTH:-}" ]; then
  AUTH="$DD_AUTH"
elif [ -n "$NONINTERACTIVE" ]; then
  AUTH="keys"
else
  echo ""
  echo "🔐 How do you want to authenticate to Datadog?"
  echo "   1) API + App keys  (quickest — paste them now, stored in the Keychain)"
  echo "   2) OAuth           (log in via the browser; needs a Datadog OAuth client)"
  echo "   3) LastPass CLI    (shared vault — keys fetched at runtime via lpass)"
  read -r -p "   Choice [1-3, default 1]: " authm
  case "${authm:-1}" in 2) AUTH="oauth" ;; 3) AUTH="lastpass" ;; *) AUTH="keys" ;; esac
fi

if [ "$AUTH" != "keys" ] && [ "$AUTH" != "oauth" ] && [ "$AUTH" != "lastpass" ]; then
  echo "❌ DD_AUTH must be 'keys', 'oauth', or 'lastpass' (got '$AUTH')" >&2
  exit 1
fi

if [ "$AUTH" = "lastpass" ]; then
  # --- LastPass CLI integration ---
  if ! command -v lpass &>/dev/null; then
    echo ""
    echo "   ⚠️  LastPass CLI (lpass) not found. Installing via Homebrew..."
    if ! command -v brew &>/dev/null; then
      echo "   ERROR: Homebrew not installed. Install it from https://brew.sh then re-run." >&2
      exit 1
    fi
    brew install lastpass-cli
    echo "   ✅ lpass installed"
  else
    echo "   ✅ lpass already installed"
  fi
  # Entry name: env first, else prompt (interactive), else error (unattended).
  if [ -n "${DD_LASTPASS_ENTRY:-}" ]; then
    LP_ENTRY="$DD_LASTPASS_ENTRY"
  elif [ -n "$NONINTERACTIVE" ]; then
    echo "❌ DD_AUTH=lastpass requires DD_LASTPASS_ENTRY in unattended mode." >&2
    exit 1
  else
    echo ""
    echo "   The tool will call 'lpass show' at runtime to fetch your team's shared keys."
    echo "   You need the LastPass entry name where the secure note is stored."
    echo ""
    echo "   Expected secure note layout (key=value lines):"
    echo "     jiraClientID=..."
    echo "     jiraClientSecret=..."
    echo "     datadogAPIKey=..."
    echo "     datadogAPPKey=..."
    echo ""
    read -r -p "   LastPass entry name (e.g. Shared-SRE/datadog-assistant): " LP_ENTRY
    if [ -z "$LP_ENTRY" ]; then
      echo "   ERROR: entry name is required." >&2
      exit 1
    fi
  fi
  # Field names: env overrides; prompt only when interactive; then default.
  LP_API_FIELD="${DD_LASTPASS_API_FIELD:-}"
  LP_APP_FIELD="${DD_LASTPASS_APP_FIELD:-}"
  LP_JIRA_CID="${DD_LASTPASS_JIRA_CID_FIELD:-}"
  LP_JIRA_SEC="${DD_LASTPASS_JIRA_SEC_FIELD:-}"
  if [ -z "$NONINTERACTIVE" ]; then
    [ -n "$LP_API_FIELD" ] || read -r -p "   Field name for Datadog API key [datadogAPIKey]: " LP_API_FIELD
    [ -n "$LP_APP_FIELD" ] || read -r -p "   Field name for Datadog App key [datadogAPPKey]: " LP_APP_FIELD
    [ -n "$LP_JIRA_CID" ] || read -r -p "   Field name for Jira OAuth client ID (leave empty to skip) [jiraClientID]: " LP_JIRA_CID
    [ -n "$LP_JIRA_SEC" ] || read -r -p "   Field name for Jira OAuth client secret [jiraClientSecret]: " LP_JIRA_SEC
  fi
  LP_API_FIELD="${LP_API_FIELD:-datadogAPIKey}"
  LP_APP_FIELD="${LP_APP_FIELD:-datadogAPPKey}"
  LP_JIRA_CID="${LP_JIRA_CID:-jiraClientID}"
  LP_JIRA_SEC="${LP_JIRA_SEC:-jiraClientSecret}"
  python3 - "$CONFIG_DIR/config.json" "$LP_ENTRY" "$LP_API_FIELD" "$LP_APP_FIELD" "$LP_JIRA_CID" "$LP_JIRA_SEC" <<'EOF'
import json, sys, os
p, entry, api_f, app_f, jira_cid, jira_sec = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["auth"] = "lastpass"
cfg["lastpass"] = {"entry": entry, "api_key_field": api_f, "app_key_field": app_f}
if jira_cid.strip():
    cfg["lastpass"]["jira_client_id_field"] = jira_cid
if jira_sec.strip():
    cfg["lastpass"]["jira_client_secret_field"] = jira_sec
json.dump(cfg, open(p, "w"), indent=2)
EOF
  echo "✅ LastPass CLI configured. Keys will be fetched from '$LP_ENTRY' at runtime."
  # Agent timeout: env first, else prompt (interactive), else 0 (never).
  if [ -n "${DD_LPASS_AGENT_TIMEOUT:-}" ]; then
    LP_TIMEOUT="$DD_LPASS_AGENT_TIMEOUT"
  elif [ -n "$NONINTERACTIVE" ]; then
    LP_TIMEOUT=0
  else
    echo ""
    echo "   ⏱  The lpass agent logs you out after a timeout (default: 1 hour)."
    read -r -p "   Session timeout in seconds (leave empty for never): " LP_TIMEOUT
    LP_TIMEOUT="${LP_TIMEOUT:-0}"
  fi
  # Must be a plain integer: it's interpolated into ~/.zshrc and the plist, so a
  # non-numeric value could inject a shell command that runs on next login.
  if ! [[ "$LP_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "   ⚠️  '$LP_TIMEOUT' is not a number of seconds — using 0 (never)." >&2
    LP_TIMEOUT=0
  fi
  # The app runs from a LaunchAgent, which does NOT source your shell rc — so
  # the authoritative place for the timeout is the plist's EnvironmentVariables
  # (wired in below). We also drop it in the shell rc so manual `lpass` use in a
  # terminal honours the same timeout.
  PLIST_TIMEOUT="$LP_TIMEOUT"
  SHELL_RC="$HOME/.zshrc"
  [ -f "$HOME/.bash_profile" ] && ! [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.bash_profile"
  if ! grep -q "LPASS_AGENT_TIMEOUT" "$SHELL_RC" 2>/dev/null; then
    echo "export LPASS_AGENT_TIMEOUT=$LP_TIMEOUT" >> "$SHELL_RC"
    echo "   ✅ Added LPASS_AGENT_TIMEOUT=$LP_TIMEOUT to $SHELL_RC"
  else
    sed -i '' "s/export LPASS_AGENT_TIMEOUT=.*/export LPASS_AGENT_TIMEOUT=$LP_TIMEOUT/" "$SHELL_RC"
    echo "   ✅ Updated LPASS_AGENT_TIMEOUT=$LP_TIMEOUT in $SHELL_RC"
  fi
  export LPASS_AGENT_TIMEOUT="$LP_TIMEOUT"
  echo "   Make sure you're logged in: lpass login your@email.com"
elif [ "$AUTH" = "oauth" ]; then
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
# LaunchAgents get a minimal environment and never source your shell rc, so any
# runtime env the app needs (e.g. LPASS_AGENT_TIMEOUT for LastPass auth) must be
# declared here.
PLIST_ENV=""
if [ -n "$PLIST_TIMEOUT" ]; then
  PLIST_ENV="  <key>EnvironmentVariables</key>
  <dict>
    <key>LPASS_AGENT_TIMEOUT</key><string>$PLIST_TIMEOUT</string>
  </dict>"
fi
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
$PLIST_ENV
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
