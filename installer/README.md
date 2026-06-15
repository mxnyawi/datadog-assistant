# 🐶 Datadog Assistant , graphical installer

A small Tkinter wizard so non-technical users can install the menu bar app
without touching Terminal. It does exactly what `../install.sh` does (venv +
`rumps`, Keychain, config, LaunchAgent), just in a window.

## What the user sees

1. **Welcome**
2. **Choose your Datadog site** (US1 / EU / US3 / US5 / AP1 / Gov)
3. **Sign in** , API + App keys (stored in the Keychain) or OAuth (Client ID;
   the browser login is finished from the menu after install)
4. **Options** , optional tag filter and company subdomain
5. **Installing** , progress + log
6. **All set** , the 🐶 appears in the menu bar

## Run it during development

```bash
python3 installer/install_gui.py        # needs a Mac with Tk (python.org build recommended)
```

## Build the distributable .app (on a Mac)

```bash
./installer/build.sh
```

This produces `installer/dist/Datadog Assistant Installer.app`, with
`datadog_assistant.py` bundled inside, using PyInstaller.

## Distribute

Zip the app and attach it to a GitHub Release (the website's Download button
points at `releases/latest`):

```bash
cd installer/dist
ditto -c -k --keepParent "Datadog Assistant Installer.app" "Datadog-Assistant-Installer.zip"
gh release create v0.3.0 "Datadog-Assistant-Installer.zip" \
  --title "Datadog Assistant 0.3.0" --notes "Graphical installer for macOS."
```

## Gatekeeper note

The app is **not** code-signed/notarized (that needs a paid Apple Developer
account), so the first launch shows an "unidentified developer" warning. Users
right-click the app and choose **Open** once. The website and the README call
this out.
