# 🐶 Datadog Assistant — building & releasing the app

The product is a single self-onboarding **`Datadog Assistant.app`**: the user
downloads it, double-clicks, and a modern GUI walks through the whole setup
(region → sign in → options → install) before it runs as the menu-bar app.
There's no separate installer anymore — the app onboards itself on first launch.

- **GUI host:** [`../onboarding_app.py`](../onboarding_app.py) (pywebview window)
- **Frontend:** [`onboarding/web/`](onboarding/web/) (HTML/CSS/JS; open
  `index.html` in a browser to preview — it falls back to a mock bridge)
- **Install engine:** [`engine.py`](engine.py) — the one place that knows how to
  set things up (venv/deps when run as a script, config, Keychain, LastPass,
  LaunchAgent). The GUI and the headless/CLI path both call it, so they can't
  drift. `DD_DRY_RUN=1 python3 engine.py` runs it headless.

## Build the app (RUN ON A MAC)

```bash
./installer/build_menubar_app.sh        # → dist/Datadog Assistant.app
open "dist/Datadog Assistant.app"
```

Uses [`../setup.py`](../setup.py) (py2app) to compile a real bundle with its own
identity + icon and `LSUIElement` (menu-bar only). The bundle id is what lets
notification clicks open the monitor and drops the generic "Python" name.

## Release (one command)

On a Mac with the GitHub CLI (`gh`) authenticated:

```bash
./installer/release.sh v0.3.0
```

It builds the Python `.app`, zips it, tags the repo, and publishes a GitHub
Release with the app attached as `Datadog-Assistant-Installer.zip`. Note:
tagged releases via CI now ship the **Swift** app (`Datadog-Assistant.dmg` /
`.zip`) — this script is only for cutting a legacy Python release by hand,
and clobbering `latest` with it will break the website's Download button.

### Build on GitHub instead of your Mac

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds the
`.app` on a macOS runner and publishes the Release automatically — no local Mac
needed. Trigger it by pushing a tag:

```bash
git tag v0.3.0 && git push origin v0.3.0
```

(or run it manually from the Actions tab via `workflow_dispatch`). It builds
the native Swift app and attaches `Datadog-Assistant.dmg` + `.zip` with
`.sha256` checksums — what the website's **Download for macOS** button points
at. `installer/release.sh` remains for cutting a legacy Python release by
hand from a Mac.

## Headless / CI install (no GUI)

`engine.py` mirrors `../install.sh`'s env-var contract for agents and CI:

```bash
DD_SITE=datadoghq.eu DD_AUTH=keys DD_API_KEY=… DD_APP_KEY=… \
  python3 installer/engine.py
```

## Gatekeeper note

The build isn't code-signed/notarized (that needs a paid Apple Developer
account), so the first launch shows an "unidentified developer" warning. Users
right-click the app and choose **Open** once.
