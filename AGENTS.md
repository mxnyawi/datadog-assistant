# AGENTS.md — guide for coding agents

Instructions for AI coding agents (Claude Code, Cursor, Copilot, etc.) setting
up, building, or contributing to **Datadog Assistant**. Humans: see
[`README.md`](README.md).

## What this is

A native macOS **menu bar** app (SwiftUI, SwiftPM package under
[`swift/`](swift/)) that surfaces Datadog monitors, incidents, and deploys,
and fires notifications. It is GUI software — it must run on a real macOS
desktop session to show its menu-bar icon. There is no headless/server mode.

> The original Python/rumps implementation is archived in
> [`legacy/python-app/`](legacy/python-app/) and is not developed anymore.
> Don't add features or fixes there.

## Prerequisites

| Requirement | Check | Notes |
|---|---|---|
| macOS 13+ | `uname` → `Darwin` | Menu bar app; will not build or run on Linux. |
| Swift 5.9+ / Xcode CLT | `swift --version` | SwiftPM only — no Xcode project. |
| Datadog credential | — | An access token (`ddpat_…`/`ddsat_…`) with scopes `monitors_read`, `monitors_downtime`, `events_read`, `incident_read`, `dashboards_read`, `timeseries_query` — or a classic API + App key pair. |

## Build / run / verify

```bash
cd swift
swift build                    # compile check (what CI runs on macOS)
./Scripts/build-app.sh         # assemble build/Datadog Assistant.app (ad-hoc signed)
DD_DEMO=1 swift run            # dev loop on generated demo data (no credentials)
open "build/Datadog Assistant.app"
```

On Linux you cannot compile this package (AppKit/SwiftUI). Use the repo's CI
(`.github/workflows/ci.yml`, macOS `swift build` job) as the compile gate:
push a branch, dispatch the CI workflow on it, and read the job logs.

## Credentials (rules for agents)

- **Never** put real tokens/keys in code, commits, config files, or your
  transcript.
- The app stores secrets on-device via `SecretStore` (Secure-Enclave-wrapped
  AES-GCM under `~/Library/Application Support/DatadogAssistant/`) — **not**
  the login Keychain, so it never password-prompts. Don't reintroduce
  Keychain APIs for app secrets.
- For the dev loop, environment variables win: `DD_BEARER_TOKEN` (or
  `DD_ACCESS_TOKEN`), or `DD_API_KEY` + `DD_APP_KEY`, plus `DD_SITE`
  (e.g. `datadoghq.eu`). `DD_DEMO=1` forces sample data.
- Credential precedence in device mode: password-manager command →
  on-device access token → on-device key pair. LastPass mode fetches from
  the shared vault at runtime and stores nothing locally.

## Contributing (for agents writing code)

- `swift build` must pass on macOS CI before proposing changes — never claim
  the app builds without a green run.
- Match the existing style: doc comments explain *why*, services are small
  single-purpose files under `Sources/DatadogAssistant/Services/`.
- No new dependencies — the package is intentionally dependency-free
  (AppKit/SwiftUI/CryptoKit/Network only).
- Update `README.md` and `swift/README.md` when you change a config key,
  credential flow, or user-facing behavior.
- State in the PR what you actually tested, and whether it was on real macOS
  (notifications, menu bar, and subprocess paths can only be verified there).
- See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full checklist.

## Release

Tag `vX.Y.Z` (or dispatch the Release workflow with that tag as input) —
`.github/workflows/release.yml` builds the app on a macOS runner, stamps the
version into Info.plist, and publishes `Datadog-Assistant.dmg` / `.zip` (+
SHA-256 checksums) to a GitHub Release. The Homebrew cask
(`Casks/datadog-assistant.rb`) tracks the latest release's zip.
