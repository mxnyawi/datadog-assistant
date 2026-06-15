# 🐶 Datadog Assistant , graphical installer

Install the menu bar app without touching Terminal. There are two builds; both
do exactly what `../install.sh` does (venv + `rumps`, Keychain, config,
LaunchAgent), just with a GUI.

## ✅ Native installer (recommended , zero dependencies)

`install.applescript` + `do_install.sh`. Uses only built-in macOS dialogs and
compiles with `osacompile`, so it needs **no Python, no Tk, no pip** , nothing to
install first.

**Test it right now (no build):**

```bash
osascript installer/install.applescript
```

**Build the double-clickable .app:**

```bash
./installer/build_app.sh        # produces "Datadog Assistant Installer.app"
```

The flow: welcome → choose Datadog site → sign in (API + App keys to the
Keychain, or an OAuth Client ID) → optional tag filter → it sets everything up
and the 🐶 appears in your menu bar.

## Single-window installer (optional , needs Tk to build)

`install_gui.py` is a Tkinter version with one continuous window. It looks nicer
but PyInstaller needs a **Tk-capable Python** to build it (the resulting .app
bundles Tk, so end users don't need anything):

```bash
brew install python-tk     # or install Python from python.org
./installer/build.sh       # builds in an isolated venv (no PEP 668 error)
```

`build.sh` checks for Tk first and tells you if it's missing. (Apple's system
`python3` and a plain Homebrew `python3` usually have **no** Tk , that's why the
native installer above is the default.)

## Distribute

Zip the app and attach it to a GitHub Release (the website's Download button
points at `releases/latest`):

```bash
cd installer
ditto -c -k --keepParent "Datadog Assistant Installer.app" "Datadog-Assistant-Installer.zip"
gh release create v0.3.0 "Datadog-Assistant-Installer.zip" \
  --title "Datadog Assistant 0.3.0" --notes "Graphical installer for macOS."
```

## Gatekeeper note

Neither build is code-signed/notarized (that needs a paid Apple Developer
account), so the first launch shows an "unidentified developer" warning. Users
right-click the app and choose **Open** once.
