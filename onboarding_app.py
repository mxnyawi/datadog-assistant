"""Onboarding GUI host — a pywebview window that runs the web frontend and
bridges it to the install engine.

This is the first-run experience of the unified Datadog Assistant.app: the
bundle launches it (via the mode switch in datadog_assistant.py) when there's
no config yet, the user walks through setup, and on finish the engine installs
the LaunchAgent and launches the menu-bar app.

pywebview is imported lazily inside run() so this module (and the Api bridge)
imports fine on Linux / in CI for unit testing.
"""
import json
import os
import sys
import threading
import webbrowser

# Make installer/engine.py importable both in the dev tree and when py2app
# flattens it to a top-level module in the bundle.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "installer"))
import engine  # noqa: E402


def web_dir():
    """Locate the web assets, whether running from the dev tree or a bundle."""
    exe_dir = os.path.dirname(sys.executable)
    bases = [getattr(sys, "_MEIPASS", None), _HERE,
             os.path.join(_HERE, "..", "Resources"),
             exe_dir,
             os.path.join(exe_dir, "..", "Resources")]  # py2app: MacOS/ → Resources/
    for base in filter(None, bases):
        for cand in (os.path.join(base, "web"),
                     os.path.join(base, "installer", "onboarding", "web")):
            if os.path.isdir(cand) and os.path.exists(
                    os.path.join(cand, "index.html")):
                return os.path.abspath(cand)
    return None


class Api:
    """Methods here are callable from JS as window.pywebview.api.<name>(arg).
    Return JSON-serializable dicts. Progress is pushed back to the page by
    evaluating the global callbacks the frontend defines."""

    def __init__(self):
        self._window = None

    # -- progress push (Python -> JS) --
    def _emit(self, fn, *args):
        win = self._window
        if not win:
            return
        try:
            call = f"window.{fn} && window.{fn}(" + \
                ", ".join(json.dumps(a) for a in args) + ")"
            win.evaluate_js(call)
        except Exception:
            pass

    # -- screens / data --
    def get_init(self, *_):
        return engine.detect_env()

    def validate_datadog_keys(self, payload=None):
        p = payload or {}
        return engine.validate_datadog_keys(
            p.get("site", "datadoghq.com"), p.get("api_key", ""),
            p.get("app_key", ""))

    # -- lastpass --
    def lastpass_ensure_cli(self, *_):
        return engine.lastpass_ensure_cli(on_log=lambda l: self._emit("ddOnLog", l))

    def lastpass_login(self, payload=None):
        p = payload or {}
        return engine.lastpass_login(
            p.get("email", ""), p.get("password", ""), p.get("otp", ""),
            never_expire=p.get("never_expire", True),
            on_log=lambda l: self._emit("ddOnLog", l))

    def lastpass_list_entries(self, *_):
        return engine.lastpass_list_entries()

    def lastpass_validate_entry(self, payload=None):
        p = payload or {}
        return engine.lastpass_validate_entry(
            p.get("entry", ""), p.get("api_key_field", ""),
            p.get("app_key_field", ""))

    # -- install --
    def begin_install(self, config=None):
        cfg = config or {}

        def worker():
            res = engine.install(
                cfg,
                on_progress=lambda f, m: self._emit("ddOnProgress", f, m),
                on_log=lambda l: self._emit("ddOnLog", l))
            self._emit("ddOnDone", bool(res.get("ok")), res.get("error", ""))

        threading.Thread(target=worker, daemon=True).start()
        return {"ok": True}

    # -- misc --
    def open_external(self, payload=None):
        url = (payload or {}).get("url", "")
        if url:
            try:
                webbrowser.open(url)
            except Exception:
                pass
        return {"ok": True}

    def finish(self, *_):
        try:
            engine.launch()
        finally:
            if self._window:
                try:
                    self._window.destroy()
                except Exception:
                    pass
        return {"ok": True}


def _promote_to_regular_app():
    """The bundle is LSUIElement (menu-bar only), so a plain window can open
    behind everything with no dock icon to click. For onboarding, promote the
    process to a regular foreground app and bring it forward. Harmless off-Mac
    or if AppKit isn't available."""
    try:
        from AppKit import (NSApplication,
                            NSApplicationActivationPolicyRegular)
        app = NSApplication.sharedApplication()
        app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
        app.activateIgnoringOtherApps_(True)
    except Exception:
        pass


def run():
    """Open the onboarding window. Raises if pywebview/web assets are missing,
    so the caller can fall back to launching the app directly."""
    import webview  # lazy: GUI-only dependency

    wd = web_dir()
    if not wd:
        raise RuntimeError("onboarding web assets not found")
    _promote_to_regular_app()
    api = Api()
    window = webview.create_window(
        "Datadog Assistant",
        url=os.path.join(wd, "index.html"),
        js_api=api,
        # Resizable + a min size so the taller steps (LastPass) are reachable
        # even before in-pane scrolling.
        width=760, height=640, min_size=(680, 560), resizable=True,
        background_color="#0f1117")
    api._window = window
    webview.start()


if __name__ == "__main__":
    run()
