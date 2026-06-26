"""Build Datadog Assistant into a real macOS .app bundle (py2app).

    pip install py2app
    python3 setup.py py2app          # standalone bundle  -> dist/Datadog Assistant.app
    python3 setup.py py2app -A       # alias/dev build (references this source tree)

Or just run installer/build_menubar_app.sh, which does the above in an
isolated build venv and generates the icon.

Why bundle the *running* app?
  As a bare `python3 datadog_assistant.py` process the app has no
  CFBundleIdentifier, so macOS cannot route a notification *click* back to it —
  clicking the side banner just opens an empty window. A real .app has an
  identifier, which is what lets the in-app notification (rumps.notification) be
  clickable and open the Datadog monitor. It also gives the app its own name and
  icon instead of appearing as "Python".

LSUIElement keeps it menu-bar-only (no dock icon, no app-switcher entry).
"""
import os
import sys

from setuptools import setup

# Make installer/engine.py importable so py2app's dependency graph picks it up
# (onboarding_app imports it via a runtime sys.path insert that the graph can't
# follow).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "installer"))

APP = ["datadog_assistant.py"]

PLIST = {
    "CFBundleName": "Datadog Assistant",
    "CFBundleDisplayName": "Datadog Assistant",
    # Matches the LaunchAgent label used by the installer.
    "CFBundleIdentifier": "com.nour.datadog-assistant",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "1.0.0",
    "LSUIElement": True,            # menu-bar app: no dock icon
    "LSMinimumSystemVersion": "10.13",
    "NSHumanReadableCopyright":
        "MIT-licensed. https://github.com/mxnyawi/datadog-assistant",
}

OPTIONS = {
    # We never read argv; emulation injects an Apple-event loop that can stall
    # a background menu-bar app.
    "argv_emulation": False,
    "plist": PLIST,
    "packages": ["rumps", "webview"],
    # onboarding_app/engine are imported lazily / via a runtime sys.path tweak,
    # so name them explicitly for the dependency graph.
    "includes": ["onboarding_app", "engine"],
    # First-run onboarding web assets → Contents/Resources/web.
    "resources": ["installer/onboarding/web"],
}

# Use the icon if it's been generated (build_menubar_app.sh makes it from the
# website PNG); otherwise build without one rather than failing.
_ICON = os.path.join("installer", "icon.icns")
if os.path.exists(_ICON):
    OPTIONS["iconfile"] = _ICON

setup(
    app=APP,
    name="Datadog Assistant",
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
