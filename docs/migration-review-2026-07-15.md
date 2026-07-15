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
