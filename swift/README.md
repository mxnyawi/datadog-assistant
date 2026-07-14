# Datadog Assistant — the native Swift app

The native Swift / SwiftUI menu-bar app — the one and only actively-developed
implementation (the original Python app is archived in
[`legacy/python-app/`](../legacy/python-app/)). Self-contained SwiftPM
package that builds a menu-bar-only `.app` bundle.

> Status: **the** Datadog Assistant — a feature-complete port of the original
> Python app (see [PARITY.md](PARITY.md)) with a native adaptive UI — system
> popover material, light/dark mode, HIG type sizes, grouped-inset sections.
> First launch shows an in-panel **Connect to Datadog** prompt (access token
> primary; API keys, a team LastPass vault, and sample data also available).
> CI compiles the package on macOS on every PR.

## Prerequisites

- macOS 13+ (Ventura or newer)
- Xcode 15+ command-line tools (`xcode-select --install`)
- `swift --version` reports 5.9+

## Build & run

```bash
cd swift
./Scripts/build-app.sh
open "build/Datadog Assistant.app"
```

A pawprint appears in the menu bar (with a red count when anything is
alerting). Click it — or press **⌥⌘D** anywhere — to open the panel.
Right-click the icon for Refresh / Settings / Quit.

With no credentials configured the panel shows a **Connect to Datadog**
prompt — paste a token right there — instead of silently serving sample data
(there's an *Explore sample data* link if you just want to look around).

**Access token (primary, 2026).** The main credential is a single scoped
Datadog **access token** — personal (`ddpat_…`, expires ≤ 1 year) or
service-account (`ddsat_…`, can be non-expiring) — sent as
`Authorization: Bearer`. Paste it in the connect prompt or Settings → Source →
*This Mac* → *Access token*, or export `DD_BEARER_TOKEN` (alias
`DD_ACCESS_TOKEN`). Required scopes are listed with a copy button right in the
setup UI: `monitors_read`, `monitors_downtime`, `events_read`,
`incident_read`, `dashboards_read`, `timeseries_query`. Token validation
probes `GET /api/v1/monitor?page_size=1` (the classic `/api/v1/validate`
endpoint only understands API keys). The classic API + Application key pair is
still available under the same tab, and `DD_API_KEY` / `DD_APP_KEY` still work
for the dev loop.

**Where secrets live (no Keychain, no password prompt).** Secrets are stored
on the device by `SecretStore`, **not** the macOS login Keychain — an
ad-hoc-signed app makes the Keychain prompt for the account password on nearly
every access, so opening the menu bar used to be a password gauntlet. Instead,
the token/keys (and the Jira and GitHub tokens) are AES-GCM encrypted in a
`0600` file under `~/Library/Application Support/DatadogAssistant`, excluded
from iCloud/Time Machine, with the key wrapped by the **Secure Enclave** when
the hardware supports it (so the file can't be decrypted on another machine or
from a backup) and a random-key fallback otherwise. This defeats casual disk
inspection, backup leakage, and other local users; it does **not** stop a
process running as you — acceptable for a scoped, revocable, expiring token.
Keep FileVault on. (Upgrading from an older build? Re-paste your token once;
the old Keychain items aren't migrated, because reading them would itself
prompt.)

Settings has a **Credential source** selector — *This Mac*, *Team LastPass*,
or *Sample data* — and the choice is remembered. The app reads from the
selected source only.

**Shared team vault (LastPass).** Instead of storing keys on each machine,
point the app at a LastPass secure note and the keys are fetched at runtime
via the `lpass` CLI — the same integration the Python app uses, reading the
same note. Right-click → Settings… → LastPass → **Set up…** opens a guided
sheet that installs the `lpass` CLI (via Homebrew), logs you in (with
authenticator support), and lets you pick and validate the entry — no
terminal needed. **Test** reads the note the way the app will (capturing the
environment and `lpass` stderr) and then probes Datadog's monitors endpoint
(which exercises BOTH keys — the classic `/api/v1/validate` ignores the app
key), printing the full transcript so a failure — a locked vault, a field-name
mismatch, or a wrong-site 403 — is diagnosable right in the window before you
save. Already logged in? Just type the entry name and hit *Use
LastPass*, or export `DD_LASTPASS_ENTRY` before launching. The note holds
`key=value` lines (or custom fields) named `datadogAPIKey` / `datadogAPPKey`
by default (override with `DD_LASTPASS_API_FIELD` / `_APP_FIELD`); an optional
`githubToken` field supplies the GitHub token for change correlation.
Credential precedence is env vars → the selected mode (LastPass vault, or this Mac's on-device store: password-manager command → access token → key pair).

**Filters, notifications, Jira.** The panel's Monitors/List tabs carry a
Filter dropdown — every tag the app has seen, grouped by key (team / env /
service…), multi-select with OR semantics, plus a name filter — matching the
Python app's `tag_filter`/`name_filter` and applied server-side. Settings is
tabbed (Source / Filters / Notifications / Jira / GitHub): notifications get
per-kind toggles, an alert-sound dropdown from `/System/Library/Sounds` (with
instant preview), and a "re-notify while still alerting" nag interval;
configuring Jira (site, email, project, issue type, API token — or the
LastPass note's `jiraToken` field) adds a one-tap "Jira ticket" action to
every alert row.

`swift run` also works for a fast dev loop, but notifications require a real
`.app` bundle, so they're disabled in that mode.

### Demo mode (for live presentations)

```bash
DD_DEMO=1 ./Scripts/build-app.sh && DD_DEMO=1 "build/Datadog Assistant.app/Contents/MacOS/DatadogAssistant"
```

Runs a scripted ~4-minute incident arc on sample data — no keys, no real org,
fully deterministic:

| t+ | beat |
|----|------|
| 0:00 | calm — everything green except two warnings |
| 0:40 | **PR #482 merges** — appears in Changes, marker lands on sparklines |
| 1:00 | **payments-api P1 fires** — hero card takes over, value climbs toward 842, suspect PR flagged, "Ns to detect" stat appears |
| 1:30 | checkout P2 follows — blast-radius chip shows "payments · 2 firing" |
| 3:30 | recovery — recovery notification, median-recovery stat fills in |

Every beat is triggered through the same transition pipeline real Datadog
data drives, so what execs watch is the actual product logic, not a video.

## Change correlation & clever queries

- **"What shipped?"** — the Changes tab merges Datadog deployment events
  (events stream, tag configurable via the `deployTag` default) with merged
  PRs from GitHub repos you watch (Settings → GitHub). Any change that landed
  ≤45 min before an alerting monitor started firing is flagged as a
  **suspect** — in the Changes feed, as a badge on the tab, and inline in the
  expanded monitor row with a one-click "View PR".
- **Week-over-week deltas** — sparkline fetches use a combined
  `"m, week_before(m)"` query, so every firing monitor knows how it compares
  to the same moment last week (×3.2 chip) at no extra API cost.
- **Threshold guide** — the monitor's critical threshold is drawn as a dashed
  line on the sparkline (shown on the hero card, and on any row once
  expanded), so "how far past the line?" is one look away.
- **Blast radius** — firing monitors sharing a `service:` tag cluster into
  chips ("payments · 3 firing") above the monitor list.
- **Snooze** — org-wide Datadog downtime (scope `*`) for 30m/1h/4h/rest of
  day from the Snooze tab; notifications pause, the panel stays live.
- **Deploy markers** — changes that landed inside the sparkline's 1h window
  are drawn as vertical ticks on the line itself: deploy tick, then the line
  goes vertical — cause and effect on one axis.
- **CI status** — latest GitHub Actions run per workflow per watched repo at
  the top of the Changes tab, failures first and counted in the tab badge.
- **Full monitor list** — footer "List" flips the panel to a searchable view
  (name or service, grouped by state, same inline mute/open actions).

## How it stays fast

- **Adaptive polling** (`SnapshotStore`): 15s cadence while anything is firing
  or recovered <5 min ago, 60s when green. The cadence is shown in the panel
  footer ("checked 4s ago · every 15s") — on-call trust requires knowing the
  latency floor, not hiding it.
- **Instant render**: the last snapshot is cached to disk and drawn
  immediately on launch/open while a live poll runs behind it. No spinners.
- **Act from the banner**: alert notifications carry "Open in Datadog" and
  "Mute 1h" buttons — no panel round-trip. P1/P2 use time-sensitive
  interruption level + critical sound.
- **Global hotkey**: ⌥⌘D toggles the panel from any app.
- Sparkline fan-out is capped at 8 concurrent metric queries per poll,
  priority-ordered, so a big monitor fleet can't slow the state fetch.

## Source layout

```
swift/
  Package.swift
  Resources/
    Info.plist                    # LSUIElement = true (menu-bar-only)
    DatadogAssistant.entitlements # hardened runtime; critical-alerts documented
  Scripts/
    build-app.sh                  # swift build + .app assembly + ad-hoc sign
    notarize.sh                   # Developer ID sign + notarytool + staple
  Sources/DatadogAssistant/
    App/
      DatadogAssistantApp.swift   # @main NSApplication bootstrap
      AppDelegate.swift           # wires store ↔ notifications ↔ hotkey ↔ UI
      MenuBarController.swift     # status item (template pawprint + badge), panel
      FloatingPanel.swift         # borderless NSPanel + NSVisualEffectView glass
      SettingsWindowController.swift
      LastPassSetupView.swift     # guided LastPass install/login/entry sheet
    Models/                       # Monitor, Incident, Snapshot (Codable)
    Services/
      DataSource.swift            # protocol: mock ↔ real swap at runtime
      DatadogClient.swift         # v1 monitors, v2 incidents, metric sparklines
      MockDataSource.swift        # sample data, no keys needed
      SnapshotStore.swift         # adaptive poll loop, disk cache, alert diffing
      Credentials.swift           # auth modes, on-device store + env vars
      LastPass.swift              # shared-vault keys via the lpass CLI
      LastPassSetup.swift         # guided install + pty login + entry validate
      NotificationManager.swift   # actionable banners, recovery notices
      HotKey.swift                # Carbon global hotkey (⌥⌘D)
    Views/                        # RootView + Theme + Components/ + Sections/
```

## Release: signing, notarization, updates

Companies won't run unsigned software, so the release path is scripted:

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
xcrun notarytool store-credentials dd-assistant --apple-id you@example.com --team-id TEAMID
export NOTARY_PROFILE=dd-assistant

./Scripts/build-app.sh && ./Scripts/notarize.sh
# → build/Datadog-Assistant.zip + .sha256, signed, notarized, stapled
```

**Critical alerts** (bypass Focus/DND for P1s): request the entitlement from
Apple (link in `Resources/DatadogAssistant.entitlements`), then uncomment the
key there. The notification code already requests `.criticalAlert` and will
use it the moment the entitlement is granted. File this early — approval takes
time.

**Auto-update (Sparkle)** is deliberately not wired yet: Sparkle ships as a
dynamic framework that must be embedded and co-signed inside the bundle, which
this hand-rolled `.app` assembly doesn't do — adding the dependency now would
produce a binary that fails at launch. It lands together with a proper Xcode
project or an SPM-artifact embed step in `build-app.sh`:
add `sparkle-project/Sparkle` ~> 2.6, `SPUStandardUpdaterController` in
`AppDelegate`, `SUFeedURL` + `SUPublicEDKey` in Info.plist, and an appcast
published from CI.

## Vorssaint design mapping

| Vorssaint section            | This app                           |
|------------------------------|------------------------------------|
| Temperatures (CPU/GPU/Bat)   | Alerting / Warning / Healthy cards |
| Hardware usage sparklines    | Per-monitor sparklines, expandable |
| Apps using significant energy| Active incidents row               |
| Memory pressure graph        | Alert pressure over time           |
| Up for 1d 22h footer         | "checked Ns ago · every Ns" + ⌥⌘D  |

Design mockups for review live in `docs/` (rendered with
`python3 docs/shoot.py`, same pipeline as the repo root).

## Still to port from the Python app

Ported since this list was first written: Jira auto-create for P1/P2 with
open-ticket dedupe, DLQ grouping, No-Data triage, local rename, and the daily
digest — see [PARITY.md](PARITY.md) for the current audit. Remaining:

- Datadog OAuth credential mode (access tokens, key pair, env, and LastPass
  cover every practical setup today)
- Monitor create/delete
