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

# 2. Datadog site/region (wrong region = 403 from the API)
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
python3 - "$CONFIG_DIR/config.json" "$SITE" <<'EOF'
import json, sys, os
p, site = sys.argv[1], sys.argv[2]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["site"] = site
json.dump(cfg, open(p, "w"), indent=2)
EOF
echo "✅ Site set to $SITE"

# 2b. Custom company subdomain (links bounce to login without it)
echo ""
echo "🏢 Does your org use a custom subdomain? (your browser shows"
echo "   <company>.$SITE instead of app.$SITE)"
read -r -p "   Company part (leave empty for app.$SITE): " SUBDOMAIN
python3 - "$CONFIG_DIR/config.json" "${SUBDOMAIN:-app}" <<'EOF'
import json, sys, os
p, sub = sys.argv[1], sys.argv[2].strip() or "app"
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["app_subdomain"] = sub
json.dump(cfg, open(p, "w"), indent=2)
EOF
[ -n "$SUBDOMAIN" ] && echo "✅ Links will use $SUBDOMAIN.$SITE" || echo "ℹ️  Using app.$SITE"

# 3. Monitor tag filter (server-side — avoids downloading every monitor in the org)
echo ""
echo "🏷  Filter monitors by tag? Only matching monitors are fetched and shown."
echo "   Strongly recommended for large orgs. Space-separated, e.g.: team:payments env:prod"
read -r -p "   Tags (leave empty for ALL monitors): " TAGS
python3 - "$CONFIG_DIR/config.json" "$TAGS" <<'EOF'
import json, sys, os
p, tags = sys.argv[1], sys.argv[2].strip()
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["tag_filter"] = tags
json.dump(cfg, open(p, "w"), indent=2)
EOF
if [ -n "$TAGS" ]; then
  echo "✅ Tag filter set to: $TAGS"
else
  echo "ℹ️  No tag filter — fetching all monitors (you can set tag_filter in config.json later)"
fi

# 4. Authentication — API + App keys, OAuth, or LastPass CLI
echo ""
echo "🔐 How do you want to authenticate to Datadog?"
echo "   1) API + App keys  (quickest — paste them now, stored in the Keychain)"
echo "   2) OAuth           (log in via the browser; needs a Datadog OAuth client)"
echo "   3) LastPass CLI    (shared vault — keys fetched at runtime via lpass)"
read -r -p "   Choice [1-3, default 1]: " authm
if [ "${authm:-1}" = "3" ]; then
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
  read -r -p "   Field name for Datadog API key [datadogAPIKey]: " LP_API_FIELD
  LP_API_FIELD="${LP_API_FIELD:-datadogAPIKey}"
  read -r -p "   Field name for Datadog App key [datadogAPPKey]: " LP_APP_FIELD
  LP_APP_FIELD="${LP_APP_FIELD:-datadogAPPKey}"
  read -r -p "   Field name for Jira OAuth client ID (leave empty to skip) [jiraClientID]: " LP_JIRA_CID
  LP_JIRA_CID="${LP_JIRA_CID:-jiraClientID}"
  read -r -p "   Field name for Jira OAuth client secret [jiraClientSecret]: " LP_JIRA_SEC
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
  echo "   Make sure you're logged in: lpass login your@email.com"
elif [ "${authm:-1}" = "2" ]; then
  echo ""
  echo "   OAuth needs a one-time OAuth client registered in Datadog"
  echo "   (Organization Settings → OAuth). Set its redirect URI to exactly:"
  echo "       http://localhost:8918/callback"
  echo "   and grant the scopes: monitors_read monitors_write monitors_downtime"
  echo "   dashboards_read incident_read metrics_read events_read"
  read -r -p "   Datadog OAuth Client ID: " DD_CLIENT_ID
  python3 - "$CONFIG_DIR/config.json" "$DD_CLIENT_ID" <<'EOF'
import json, sys, os
p, cid = sys.argv[1], sys.argv[2].strip()
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["auth"] = "oauth"
cfg["oauth_client_id"] = cid
json.dump(cfg, open(p, "w"), indent=2)
EOF
  echo "✅ OAuth selected. After launch, click 🐶 → Preferences →"
  echo "   🔐 Datadog credentials → OAuth to finish the browser login."
else
  read -r -p "   Store your Datadog keys in the macOS Keychain now? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -r -s -p "   Datadog API key: " API_KEY; echo
    read -r -s -p "   Datadog APP key: " APP_KEY; echo
    security add-generic-password -U -s datadog-assistant-api-key -a "$USER" -w "$API_KEY"
    security add-generic-password -U -s datadog-assistant-app-key -a "$USER" -w "$APP_KEY"
    # auth=keys + use_keychain=true in config
    python3 - "$CONFIG_DIR/config.json" <<'EOF'
import json, sys, os
p = sys.argv[1]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["auth"] = "keys"
cfg["use_keychain"] = True
json.dump(cfg, open(p, "w"), indent=2)
EOF
    echo "✅ Keys stored in Keychain"
  else
    echo "ℹ️  OK — put your keys in $CONFIG_DIR/config.json (api_key / app_key)"
  fi
fi

# 5. LaunchAgent (start at login, keep alive)
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
