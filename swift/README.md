# Datadog Assistant — Swift rewrite

A native Swift / SwiftUI rewrite of the menu-bar app, branched off `main` so
the original Python app keeps working untouched. Self-contained SwiftPM
package that builds a menu-bar-only `.app` bundle.

> Status: **feature-complete port** (see [PARITY.md](PARITY.md)) with a
> native adaptive UI — system popover material, light/dark mode, HIG type
> sizes, grouped-inset sections. First launch shows a welcome window that
> sets up the team LastPass vault (recommended), pasted API keys, or sample
> data. CI compiles the package on macOS on every PR.

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

With no credentials configured the app runs on **sample data** (a "SAMPLE"
badge shows in the header). Add real keys via right-click → Settings…, or
export `DD_API_KEY` / `DD_APP_KEY` / `DD_SITE` before launching. Keys saved
through Settings go to the macOS Keychain under the same service names the
Python app uses (`datadog-assistant-api-key` / `-app-key`), so an existing
install carries over automatically.

**Access tokens (2026).** Alongside the classic API + Application key pair,
the app accepts a single scoped Datadog **access token** — personal
(`ddpat_…`, expires ≤ 1 year) or service-account (`ddsat_…`, can be
non-expiring) — sent as `Authorization: Bearer`. Pick *Access token* in
Settings → Source (or in the onboarding sheet), or export `DD_BEARER_TOKEN`
(alias `DD_ACCESS_TOKEN`). Required scopes: `monitors_read`,
`monitors_downtime`, `events_read`, `incident_read`, `dashboards_read`,
`timeseries_query`. Token validation probes `GET /api/v1/monitor?page_size=1`
(the classic `/api/v1/validate` endpoint only understands API keys). A
LastPass note can hold the token too: set the field name via
`DD_LASTPASS_TOKEN_FIELD` (empty by default, so existing key-pair notes are
untouched). Saving a token clears stored keys and vice versa — the two
shapes never shadow each other.

Settings has a **Credential source** selector — *Sample data*, *Keychain*, or
*LastPass* — and the choice is remembered. The app reads from the selected
source only: pick *LastPass* and it never touches (or prompts for) the
Keychain; pick *Sample data* and it stays offline. Environment variables
(`DD_API_KEY` / `DD_APP_KEY`) still override everything for the dev loop.

**Shared team vault (LastPass).** Instead of storing keys on each machine,
point the app at a LastPass secure note and the keys are fetched at runtime
via the `lpass` CLI — the same integration the Python app uses, reading the
same note. Right-click → Settings… → LastPass → **Set up…** opens a guided
sheet that installs the `lpass` CLI (via Homebrew), logs you in (with
authenticator support), and lets you pick and validate the entry — no
terminal needed. **Test** reads the note the way the app will (capturing the
environment and `lpass` stderr) and then calls Datadog's `/api/v1/validate`,
printing the full transcript so a failure — a locked vault, a field-name
mismatch, or a wrong-site 403 — is diagnosable right in the window before you
save. Already logged in? Just type the entry name and hit *Use
LastPass*, or export `DD_LASTPASS_ENTRY` before launching. The note holds
`key=value` lines (or custom fields) named `datadogAPIKey` / `datadogAPPKey`
by default (override with `DD_LASTPASS_API_FIELD` / `_APP_FIELD`); an optional
`githubToken` field supplies the GitHub token for change correlation.
Credential precedence is env vars → LastPass → Keychain.

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
      Credentials.swift           # Keychain (shared with Python app) + env vars
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

- Jira auto-create for P1/P2 + dedupe (manual per-alert tickets work today)
- DLQ grouping, No-Data triage, local rename
- OAuth credential mode (Keychain, env, and LastPass work today)
- Daily digest
- Monitor create/delete
