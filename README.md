# 🐶 Datadog Assistant — macOS menu bar app

Your personal Datadog sidekick that lives in the menu bar and makes alerts
**impossible to ignore** — because emails and Teams messages get lost.

## ✨ What it does

| | |
|---|---|
| 🚨 | Menu bar icon flips from 🐶 to **🚨 2** the second a monitor alerts |
| 🛑 | Optional **modal popup** (critical alert you must dismiss) + 🪧 banner + 🔊 sound |
| 🔴🟡🟢 | All monitors grouped by state — Alert / Warn / No Data / OK / Muted |
| 🔇 | Mute any monitor for 1h / 4h / 24h / forever, unmute, 🗑 delete (type-DELETE confirm) |
| ➕ | Create new metric monitors from the menu bar |
| 🔗 | Quick links: Dashboards, Monitors, Logs, APM, Incidents + your own custom links |
| 😴 | Snooze all alerting for 30m / 1h / 4h / rest of day |
| 🏷 | Tag + name filters so you only see *your* team's monitors |
| 🔁 | Re-notifies every N minutes while a monitor is **still** alerting |
| 🟢 | Recovery notifications when things go back to OK |
| 🔐 | Keys via macOS Keychain (recommended), config file, or env vars |
| 🌐 | Works with every Datadog site (US1/EU/US3/US5/AP1/Gov) |

## 🚀 Install (on your Mac)

```bash
cd datadog-assistant
chmod +x install.sh
./install.sh
```

The installer:
1. creates a venv at `~/.datadog-assistant` and installs `rumps`
2. offers to store your **API key** and **APP key** in the macOS Keychain 🔐
3. installs a LaunchAgent so the app starts at login and stays alive

Then look for **🐶** in your menu bar. Use **🩺 Test Notification** to verify
banners/popups work (grant notification permission if macOS asks).

> 🔑 Get keys at **Organization Settings → API Keys / Application Keys**.
> The app key needs the `monitors_read` / `monitors_write` /
> `monitors_downtime` scopes.

### Run manually instead

```bash
pip3 install rumps
DD_API_KEY=xxx DD_APP_KEY=yyy python3 datadog_assistant.py
```

## ⚙️ Customization — `~/.config/datadog-assistant/config.json`

Everything is configurable (see `config.example.json` for a full example):

- **`icons`** — change every menu bar emoji (🐶/🚨/⚠️/🤷/😴/🔌) and toggle the alert count
- **`notifications.style`** — `"banner"`, `"modal"` (the unmissable popup), or `"both"`
- **`notifications.sound_name`** — any macOS sound: `Sosumi`, `Glass`, `Hero`, `Submarine`, `Funk`…
- **`notifications.renotify_minutes`** — nag interval while still alerting (0 = off)
- **`tag_filter`** / **`name_filter`** — scope to your team, e.g. `"team:payments env:prod"`
- **`quick_links`** — Datadog pages (relative paths, follow your `site`)
- **`custom_links`** — any URL: dashboards, runbooks, wikis
- **`menu.group_order`**, **`menu.show_ok_monitors`**, **`menu.max_per_group`**
- **`refresh_seconds`** — poll interval (min 15s; mind your API rate limits)

Most common settings are also flippable live from **⚙️ Preferences** in the
menu — no editing or restart needed.

## 🧯 Troubleshooting

- **🔌 in the menu bar** → API error. Check keys/site; hover the first menu row for the message.
- **No banners** → System Settings → Notifications → allow alerts for the script/Terminal.
- **Logs** → `~/.datadog-assistant/stderr.log`
- **Uninstall** →
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
  rm -rf ~/.datadog-assistant ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
  ```
