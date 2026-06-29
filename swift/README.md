# Datadog Assistant — Swift rewrite (prototype)

A native Swift / SwiftUI rewrite of the menu-bar app, branched off `main` so
the original Python app keeps working untouched. This sub-tree is a
self-contained SwiftPM package that builds a menu-bar-only `.app` bundle.

> Status: **UI prototype.** The popover renders against a mock data source so
> you can see the layout and judge the visual direction. The Datadog / Jira /
> Keychain / notification layers from `datadog_assistant.py` are not ported
> yet — that's the next step once the look is approved.

## Prerequisites

- macOS 13+ (Ventura or newer)
- Xcode 15+ command-line tools (`xcode-select --install`)
- `swift --version` reports 5.9+

## Build & run

From the repo root:

```bash
cd swift
./Scripts/build-app.sh
open "build/Datadog Assistant.app"
```

A 🐶 icon appears in the menu bar. Click it to open the popover. The mock
source ticks every two seconds, so the sparklines and counters animate.

Or, for a fast dev loop:

```bash
swift run    # foreground console process; Ctrl-C to stop
```

`swift run` launches the executable directly (no `.app` wrapper), so it
behaves as an `accessory`-policy app via `setActivationPolicy(.accessory)`.

## Open in Xcode

```bash
open Package.swift
```

Xcode will resolve the package and offer `DatadogAssistant` as a runnable
scheme. Use this for SwiftUI previews on the views under `Sources/.../Views/`.

## Source layout

```
swift/
  Package.swift
  Resources/Info.plist          # LSUIElement = true (menu-bar-only)
  Scripts/build-app.sh          # swift build + .app bundle assembly
  Sources/DatadogAssistant/
    App/
      Main.swift                # NSApplication bootstrap
      AppDelegate.swift         # owns the data source + MenuBarController
      MenuBarController.swift   # NSStatusItem + NSPopover wiring
    Models/                     # Monitor, Incident, Snapshot
    Services/
      MockDataSource.swift      # animated fake snapshot, no API keys needed
    Views/
      RootView.swift            # popover content
      Theme.swift               # colors
      Components/               # Sparkline, StateCard, MonitorRow, ...
      Sections/                 # StateSection, ActiveMonitorsSection, ...
```

## Mapping vs. the Vorssaint screenshot

The popover keeps Vorssaint's layout vocabulary but shows Datadog data:

| Vorssaint section            | Datadog Assistant section          |
|------------------------------|------------------------------------|
| Temperatures (CPU/GPU/Bat)   | Alert state (Alerting/Warning/OK)  |
| Hardware usage sparklines    | Per-monitor sparklines             |
| Apps using significant energy| Active incidents row               |
| Memory pressure graph        | Alert activity over time           |

## Not implemented yet

- Real Datadog API client (only `MockDataSource` so far)
- Keychain / OAuth / LastPass credential modes
- Jira ticketing
- Per-monitor mute / delete / rename
- macOS notifications + critical modal
- Settings panel (the gear button in the footer is a no-op)
- Monitor list view (the list button is a no-op)
- Glass `NSPanel` backing — currently uses `NSPopover`'s default chrome; a
  follow-up will swap in a borderless `NSPanel` + `NSVisualEffectView` to
  match Vorssaint's translucent look more closely.

## Why the rewrite

See the conversation that produced this branch — short version: matching the
Vorssaint visual language in `rumps` isn't possible (`rumps` only renders a
native `NSMenu`), and doing it in PyObjC means hand-bridging every AppKit
call. SwiftUI gets us `Material`, `Charts`, declarative state, and native
animations for less code, and the resulting binary doesn't need to ship a
Python runtime.
