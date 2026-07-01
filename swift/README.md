# Datadog Assistant — Swift rewrite

A native Swift / SwiftUI rewrite of the menu-bar app, branched off `main` so
the original Python app keeps working untouched. Self-contained SwiftPM
package that builds a menu-bar-only `.app` bundle.

> Status: **functional prototype.** Real Datadog client, glass panel UI,
> actionable notifications, global hotkey, settings window. Written on Linux —
> compiles-on-first-try is not guaranteed; expect to fix small type errors on
> first `swift build`. Jira, DLQ grouping, No-Data triage, and per-monitor
> rename from the Python app are not ported yet.

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

`swift run` also works for a fast dev loop, but notifications require a real
`.app` bundle, so they're disabled in that mode.

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
  line on the sparkline, so "how far past the line?" is visible at a glance.
- **Blast radius** — firing monitors sharing a `service:` tag cluster into
  chips ("payments · 3 firing") above the monitor list.
- **Snooze** — org-wide Datadog downtime (scope `*`) for 30m/1h/4h/rest of
  day from the Snooze tab; notifications pause, the panel stays live.

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
      Main.swift                  # NSApplication bootstrap
      AppDelegate.swift           # wires store ↔ notifications ↔ hotkey ↔ UI
      MenuBarController.swift     # status item (template pawprint + badge), panel
      FloatingPanel.swift         # borderless NSPanel + NSVisualEffectView glass
      SettingsWindowController.swift
    Models/                       # Monitor, Incident, Snapshot (Codable)
    Services/
      DataSource.swift            # protocol: mock ↔ real swap at runtime
      DatadogClient.swift         # v1 monitors, v2 incidents, metric sparklines
      MockDataSource.swift        # sample data, no keys needed
      SnapshotStore.swift         # adaptive poll loop, disk cache, alert diffing
      Credentials.swift           # Keychain (shared with Python app) + env vars
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

- Jira ticketing (create per alert, auto-create P1/P2, dedupe)
- DLQ grouping, No-Data triage, local rename
- OAuth + LastPass credential modes (Keychain + env work today)
- Snooze-all, re-notify nag loop, daily digest
- Monitor create/delete
