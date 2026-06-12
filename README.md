# 🐶 Datadog Assistant — macOS menu bar app

Your personal Datadog sidekick that lives in the menu bar and makes alerts
**impossible to ignore** — because emails and Teams messages get lost.

> ⚠️ Unofficial personal tool — not affiliated with or endorsed by Datadog,
> Inc. or Atlassian. You bring your own API keys.

## ✨ What it does

| | |
|---|---|
| 🚨 | Menu bar icon flips from 🐶 to **🚨 2** the second a monitor alerts |
| 🛑 | Optional **modal popup** (critical alert you must dismiss) + 🪧 banner + 🔊 sound |
| 🔴🟡🟢 | All monitors grouped by state — Alert / Warn / No Data / OK / Muted |
| 🤫 | **No Data triage** — splits No Data into *likely broken* (metric was flowing then stopped, monitor wants no-data alerts) vs *expected quiet* (no-data notifications off, event-stream monitors, stale/retired, metric silent for 24h+). Only broken ones notify; quiet ones collapse into a 🤫 submenu with the reason |
| 🔇 | Mute any monitor for 1h / 4h / 24h / forever, unmute, 🗑 delete (type-DELETE confirm) |
| ➕ | Create new metric monitors from the menu bar |
| 🔗 | Quick links: Dashboards, Monitors, Logs, APM, Incidents + your own custom links |
| 😴 | Snooze all alerting for 30m / 1h / 4h / rest of day |
| 🏷 | Tag + name filters so you only see *your* team's monitors |
| 🔁 | Re-notifies every N minutes while a monitor is **still** alerting |
| 🟢 | Recovery notifications when things go back to OK |
| 🔐 | Keys via macOS Keychain (recommended), config file, or env vars |
| 🌐 | Works with every Datadog site (US1/EU/US3/US5/AP1/Gov) |
| 🎯 | **Severity engine** — per-priority (P1–P5) notification rules: P1 gets modal + 10-min nag, P3 just a banner |
| 📈 | **Live context on every alert**: sparkline of the metric, current value vs critical threshold |
| ⏱ | How long it's been alerting + 📟 which hosts/groups triggered |
| 🔥 | Active Datadog **incidents** (SEV-1…5) right in the menu |
| 📊 | Your real dashboards auto-populated into Quick Links |
| 🌅 | Optional daily digest notification (`digest_hour`) |
| 🎫 | **Jira integration** — create tickets per alert from the menu, or auto-create for P1/P2, with open-ticket dedupe |

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
- **`browser`** — open links in a specific browser, e.g. `"Google Chrome"`,
  `"Firefox"`, `"Arc"`. Empty = system default. Set this if every link asks
  you to log in: links were opening in the default browser (often Safari)
  instead of the one holding your Datadog session.
- **`app_subdomain`** — orgs with a custom subdomain (you normally browse
  `yourorg.datadoghq.eu`) should set `"yourorg"`, otherwise deep links to
  `app.<site>` bounce you to the login page.
- **`quick_links`** — Datadog pages (relative paths, follow your `site`)
- **`custom_links`** — any URL: dashboards, runbooks, wikis
- **`menu.group_order`**, **`menu.show_ok_monitors`**, **`menu.max_per_group`**
- **`refresh_seconds`** — poll interval (min 15s; mind your API rate limits)

New in v0.2:

- **`severity.rules`** — per-priority behavior. Priority is read from the
  monitor's priority field, a `priority:p1` tag, or `[P1]` in the name.
  Each rule can set `style`, `renotify_minutes`, `icon` (menu bar), `sound_name`.
- **`context`** — toggles for sparklines 📈, triggered groups 📟,
  incidents 🔥, and auto dashboard links 📊.
- **`digest_hour`** — e.g. `9` for a morning summary banner; `null` to disable.
- **`jira`** — see below.
- **`no_data_triage`** — smart No Data classification. A monitor in No Data is
  *quiet* (🤫 collapsed submenu, no notification) when: its author turned
  no-data notifications off / set it to resolve on missing data; it watches an
  event stream (log/event/RUM/CI monitors — zero events is usually healthy);
  it's been silent longer than `stale_hours` (default 48 — retired host,
  seasonal job); or a live probe finds zero datapoints across the last
  `probe_lookback_hours` (default 24). It's *likely broken* (top-level ⚪
  group + notification, with the reason attached) when the monitor wants
  no-data alerts — especially when the probe shows the metric **was flowing
  and then stopped** (dead agent/host). Probes are capped at `max_probes`
  metric queries per refresh; set `"enabled": false` for the old flat
  behavior. Ambiguity defaults to *broken* — a dead service looks exactly
  like No Data.

Most common settings are also flippable live from **⚙️ Preferences** in the
menu — no editing or restart needed.

## 🎫 Jira integration (works with Okta SSO)

Tickets are created via the Jira Cloud REST API using an **Atlassian API
token** — these authenticate directly against Atlassian, so they work even
when your company logs into Jira through Okta. (A full Okta OAuth flow is
only needed for self-hosted Jira Data Center, which this doesn't support yet.)

**Easiest setup:** click **Preferences → 🎫 Jira integration** in the menu —
a wizard asks for your Jira URL, email, API token (create one at
**id.atlassian.com → Security → API tokens**), project key, and ticket
labels. The token goes into the macOS Keychain, not the config file.
Labels are added to every ticket — give each team its own (e.g.
`team-payments`) so their board filters pick up the right tickets. To fix a wrong token or
change any value later, use **Preferences → 🎫 Edit Jira settings…** (leave
the token blank to keep the current one).

Manual setup instead:

1. Create a token at **id.atlassian.com → Security → API tokens**
2. Store it (Keychain recommended):
   ```bash
   security add-generic-password -U -s datadog-assistant-jira-token -a "$USER" -w "<token>"
   ```
3. In config: set `jira.enabled: true`, your `base_url`, `email`, `project_key`
4. Optional: `auto_create: true` auto-files a ticket whenever a monitor with
   priority ≤ `auto_create_max_p` (default P1/P2) newly alerts

Every ticket gets a `dd-monitor-<id>` label; with `dedupe: true` a new ticket
is skipped while one for that monitor is still open. Each alerting monitor's
submenu shows **🎫 Create Jira ticket** (and **🎫 Open OPS-123** once one exists).

## 🗺 Roadmap ideas (API already supports these)

- 🪵 Recent error logs per alerting service (Logs Search API)
- 🎯 SLO error-budget section (SLO API)
- 🌐 Failing Synthetics checks
- 📰 Event stream (deploys correlated with alerts)
- 🖥 Host up/down counts, 💸 usage/cost watch

## 🛡 macOS hardening (built in)

- **App Nap immunity** — macOS throttles timers of "idle" background apps,
  which would delay alert polling. The app holds an `NSProcessInfo` activity
  token, and the LaunchAgent runs with `ProcessType: Interactive`.
- **Single instance** — an `flock` lockfile prevents a manual run + the
  LaunchAgent from producing two menu bar icons.
- **No stale-alert blind spots** — a transient API/network error shows a
  🔌 row in the menu but never replaces a known alerting icon in the menu bar.
- **Leak-safe menu updates** — the menu only rebuilds when content actually
  changes (rumps leaks Cocoa objects on rebuild), with a 5-minute cap while
  anything is alerting so "triggered Xm ago" stays fresh.
- **Duplicate-name safe** — rumps menus key items by title; identical monitor
  names are disambiguated invisibly so none vanish.
- **Permission-free critical alerts** — banners need notification permission
  (they attribute to "Python" in System Settings), but the modal popup uses
  `display alert`, which macOS always shows. Your unmissable path can't be
  silently disabled.

## 🧯 Troubleshooting

- **🔌 in the menu bar** → API error. Check keys/site; hover the first menu row for the message.
- **403 Forbidden** → almost always the wrong region: your keys belong to a different Datadog site than `site` in the config. Re-run `install.sh` and pick your region, or set `site` (e.g. `datadoghq.eu`) in `~/.config/datadog-assistant/config.json` / via 🌐 in Preferences.
- **No banners** → System Settings → Notifications → allow alerts for the script/Terminal.
- **Every link asks me to log in** → links open in your *default* browser, which may not
  hold your Datadog session. Set `"browser": "Google Chrome"` (or wherever you're logged
  in) in the config. If your org uses a custom subdomain (`yourorg.datadoghq.eu`), also
  set `"app_subdomain": "yourorg"`.
- **Logs** → `~/.datadog-assistant/stderr.log`
- **Uninstall** →
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
  rm -rf ~/.datadog-assistant ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
  ```
