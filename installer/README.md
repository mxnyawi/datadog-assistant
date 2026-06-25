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

It builds the `.app`, zips it, tags the repo, and publishes a GitHub Release with
the app attached as `Datadog-Assistant-Installer.zip` (name kept for backwards
compatibility). The website Download button
(`releases/latest/download/Datadog-Assistant-Installer.zip`) then resolves.

### Optional: build on GitHub instead of your Mac

There's no release workflow yet — releases are built and published **locally**
with `installer/release.sh` on a Mac. A `.github/workflows/release.yml` that
builds the `.app` on a macOS runner and publishes on a `v*` tag would remove the
need for a local Mac; contributions welcome. (Committing a workflow file needs a
token with the `workflow` scope, or adding it via the GitHub web UI.)

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
