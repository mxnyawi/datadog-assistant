# SwiftUI migration review — 2026-07-15

Post-migration audit of the features list ([`swift/PARITY.md`](../swift/PARITY.md))
against the actual Swift source, one day after main switched from the Python
app to the SwiftUI app. Every claim below was verified in code, not just in
docs.

## 1. What we did well

**Parity is real, not aspirational.** Spot-checks of PARITY.md's ✅ rows all
held up in source: single-instance flock (`DatadogAssistantApp.swift`), daily
digest (`NotificationManager.swift` + hour picker in Settings), mute/unmute
with durations (`MonitorRow`), local renames, priority detection, LastPass
guided setup with diagnostics, Jira OAuth as the default auth mode with JQL
dedupe, DLQ grouping, No-Data triage with live metric probes, and
snooze-via-API-downtime (stronger than Python's local-only snooze).

**The Swift app exceeds the Python app in several places** (documented as
"Swift-only bonus" and confirmed): graphical sparklines with threshold lines
and deploy markers, "×N vs last week" deltas, actionable notification banners,
disk cache for instant first render, adaptive 15s/60s polling, the Changes tab
(GitHub merges + CI runs + deploy correlation), service cluster chips, and
zero-setup GitHub auth borrowed from the `gh` CLI.

**Auth moved forward, not just sideways.** The app now supports Datadog
access tokens (`ddpat_…`/`ddsat_…`) as the primary credential — a mode the
Python app never had — plus the classic key pair, LastPass vault, secret
commands, and env overrides. Secrets avoid the login Keychain entirely
(AES-GCM, Secure-Enclave-wrapped `SecretStore`).

**The repo tells one story.** Python is archived under `legacy/` with docs and
a `python-final` tag, CI gates only the Swift app, README/AGENTS.md/PR
template are Swift-first, and the old Python-era PRD's success criteria
(no Terminal, real bundle identity, in-app onboarding, clickable
notifications) are all met by the Swift app.

## 2. What we missed

**Zero automated tests.** The Swift package has no test target at all
(`Package.swift` defines only the executable; no `swift/Tests/`), and CI runs
only `swift build` + bundle assembly. The legacy Python app had smoke,
onboarding, and installer-engine tests — the migration *lost* test coverage.
This is the biggest engineering-health gap.

**PARITY.md drifted from the code it audits** (corrected in this commit):

- It never mentioned the access-token auth mode, and still called Datadog
  OAuth PKCE "the biggest auth gap" — access tokens now cover the key-less
  use case, so PKCE is deprioritized.
- Everything else in it checked out; its ❌/🟡 rows are accurate.

**Confirmed still-missing features** (each verified absent in source):

- Service context from the Software Catalog (`/api/v2/services/definitions`:
  repo/runbook/on-call links, version/commit) — the biggest remaining port.
- Notify when a mute lifts and the monitor is still firing.
- Monitor create/delete (the only `DELETE` call is downtime cancellation).
- A general Datadog "Test connection" button (the only `testConnection` is
  Jira's; Datadog validation exists only inside LastPass setup and the
  connect prompt).
- Subdomain guess from `GET /api/v1/org`, custom quick-links UI,
  group-order/hide-OK settings, refresh-interval override.

**Distribution friction remains.** The app is ad-hoc signed, not notarized —
installs require `--no-quarantine` or right-click → Open. `Scripts/notarize.sh`
exists but isn't wired into the release workflow (needs an Apple Developer ID,
a human dependency). There is also no auto-update mechanism beyond the
Homebrew cask.

## 3. Next work (ranked, for the next agent)

1. **Add a test target and gate CI on it.** Extract pure logic —
   No-Data-triage ladder, DLQ pattern matching, priority detection,
   deploy-correlation windowing, alias mapping, credential precedence — into
   unit-testable form; add `swift test` to `ci.yml`. Restores the coverage
   lost in the migration and protects everything below.
2. **Service context milestone** (PARITY gap #1): hourly fetch of
   `/api/v2/services/definitions`, parse links per schema version, merge with
   links scraped from monitor messages, render in the expanded row.
3. **Notify on mute-lift while still firing** — small diff in the snapshot
   store's muted→unmuted transition handling.
4. **Notarized releases**: wire `Scripts/notarize.sh` into `release.yml`
   behind repo secrets (blocked on an Apple Developer ID — ask the user).
5. **Settings polish batch**: general Datadog connection test, subdomain
   guess from `GET /org`, custom quick-links UI, hide-OK/group-order toggles,
   refresh-interval override.
6. **Deprioritized**: Datadog OAuth PKCE (access tokens cover it), monitor
   create/delete (rare from a menu bar; delete needs typed-DELETE
   confirmation).

## 4. UI/UX feature backlog (new, beyond parity)

The panel already has hover states, press micro-interactions (Reduce-Motion
aware), a group heatmap, cluster chips, and an MTTR strip — these ideas build
on that baseline. Ranked by value-per-effort; none duplicate existing UI.

1. **Keyboard navigation + command palette.** Arrow keys to move through
   rows, Return to expand, `m` to mute, `o` to open in Datadog; a ⌘K
   fuzzy-find over monitor names that jumps to (or acts on) a monitor. The
   panel already opens from anywhere via ⌥⌘D — power users should never need
   the mouse once it's open. (`onKeyPress`/`focusable` on `MonitorListSection`;
   palette as an overlay over `RootView`.)
2. **Pin the panel open.** A pin toggle in `HeaderView` that keeps the
   `FloatingPanel` up while clicking elsewhere (it already sets
   `hidesOnDeactivate = false`; pinning means suppressing the close-on-
   click-outside path) — an on-call "keep it on my second display" mode.
3. **Pinned/favorite monitors.** Star a monitor to keep it at the top above
   the state groups, persisted like local renames. Cheap, high daily value.
4. **Alert timeline view.** A scrubbable "last 24 h" lane per monitor —
   state transitions, deploy markers, mutes — built from `SnapshotStore`
   history the app already persists. Answers "when did this start and what
   happened around it" without opening Datadog.
5. **Sparkline hover tooltips.** Value + timestamp under the cursor, and the
   deploy marker's PR/commit on hover. The data is already in the view;
   this is pure affordance.
6. **Menu-bar badge preferences.** Choose what the count means (all alerting
   vs P1/P2 only vs unmuted only) and an optional subtle pulse on a new
   alert (respecting Reduce Motion). One person's signal is another's noise —
   today's badge is fixed in `MenuBarController`.
7. **Right-click quick menu on the status item.** Native NSMenu with
   Refresh / Snooze 1 h / Open Datadog / Settings / Quit — actions without
   opening the panel, matching how system status items behave.
8. **Copy-as-Markdown/Slack for an alert.** One action on the expanded row
   (and hero card) that copies name, state, duration, value vs threshold,
   suspect deploy, and deep links — formatted for pasting into an incident
   channel. Complements the existing Jira action.
9. **macOS Focus / Do Not Disturb awareness.** Follow system Focus: while
   on, downgrade banners per the per-priority rules (e.g. only P1 modals
   break through). Cheaper than a scheduler and matches user expectations.
10. **Notification Center widget.** A WidgetKit glance (worst state + counts
    + top firing monitor). Note: needs a widget extension target, which
    SwiftPM alone can't bundle cleanly — scope carefully before starting.
11. **Accessibility pass.** VoiceOver labels for sparkline/heatmap/state
    tiles (summarize the data, not the pixels), full keyboard reachability
    (pairs with #1), and a contrast audit of the state colors in both themes.
12. **Density setting.** Compact row mode (single-line, smaller sparklines)
    for people watching 50+ monitors on a laptop screen.
