#!/bin/bash
# Dev helper: full clean reinstall + rebuild + fresh onboarding, in one shot.
# Run from the repo root after pulling:   git pull && ./installer/dev-retest.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PLIST="$HOME/Library/LaunchAgents/com.nour.datadog-assistant.plist"

echo "▶ Stopping any running / loaded instance…"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "Datadog Assistant" 2>/dev/null || true
pkill -f lpass 2>/dev/null || true

echo "▶ Clearing state (config, lock, logs)…"
rm -f "$HOME/.config/datadog-assistant/app.lock"
rm -f "$HOME/.datadog-assistant/startup.log" "$HOME/.datadog-assistant/stderr.log"
if [ -f "$HOME/.config/datadog-assistant/config.json" ]; then
  mv "$HOME/.config/datadog-assistant/config.json" "/tmp/dd-config.bak.$$"
  echo "   (backed up your config.json to /tmp/dd-config.bak.$$)"
fi

echo "▶ Rebuilding the app…"
rm -rf build dist
./installer/build_menubar_app.sh

echo "▶ Launching onboarding…"
open "dist/Datadog Assistant.app"

cat <<'MSG'

✅ Onboarding launched. Finish it, then check:

   pgrep -fl "Datadog Assistant"          # expect ONE running process
   launchctl list | grep datadog          # expect a real PID in column 1
   cat ~/.datadog-assistant/startup.log   # the run-mode trace

MSG
