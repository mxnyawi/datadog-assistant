#!/usr/bin/env bash
# Render all 10 marketing compositions, 3 in parallel.
set -u
cd /home/user/datadog-assistant
export HYPERFRAMES_BROWSER_PATH=/opt/pw-browsers/chromium-1194/chrome-linux/chrome
export PRODUCER_MAX_WORKERS=1
CLI="node node_modules/hyperframes/dist/cli.js"
mkdir -p Marketing/build/logs

render_one() {
  local dir="$1"
  local slug orient out
  orient=$(basename "$(dirname "$dir")")
  slug=$(basename "$dir")
  out="$dir/renders/${slug}.mp4"
  local log="Marketing/build/logs/${orient}-${slug}.log"
  if node node_modules/hyperframes/dist/cli.js render "$dir" --skill=motion-graphics -q high -o "$out" >"$log" 2>&1; then
    echo "OK   $out"
  else
    echo "FAIL $dir (see $log)"
  fi
}
export -f render_one
export HYPERFRAMES_BROWSER_PATH PRODUCER_MAX_WORKERS

printf '%s\n' Marketing/landscape/* Marketing/tiktok/* \
  | xargs -I{} -P 3 bash -c 'render_one "$@"' _ {}
echo "=== ALL RENDERS DONE ==="
