"""Smoke test: stub rumps + osascript, feed fake monitors through the app's
state machine and menu builder. Runs on Linux (no macOS needed)."""
import sys, types, os, json, time, tempfile

# ---- stub rumps ----
rumps = types.ModuleType("rumps")

class MenuItem:
    def __init__(self, title, callback=None, key=None):
        self.title, self.callback, self.state = title, callback, 0
        self.children = []
    def add(self, item):
        self.children.append(item)

class Timer:
    def __init__(self, cb, interval): self.cb, self.interval = cb, interval
    def start(self): pass
    def stop(self): pass

class App:
    def __init__(self, name, title=None, quit_button=None):
        self.name, self.title = name, title
        self._menu = []
    @property
    def menu(self): return self._menu
    @menu.setter
    def menu(self, items): self._menu = list(items)

class Window:
    def __init__(self, **kw): pass
    def run(self): raise RuntimeError("no GUI in test")

rumps.MenuItem, rumps.Timer, rumps.App, rumps.Window = MenuItem, Timer, App, Window
rumps.quit_application = lambda *a: None
rumps.notification = lambda *a, **k: None
sys.modules["rumps"] = rumps

# patch menu.clear since list has clear but App.menu returns list — fine.
import unittest.mock as mock

# ---- isolate config dir ----
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp

import datadog_assistant as da
da.CONFIG_DIR = os.path.join(tmp, "cfg")
da.CONFIG_PATH = os.path.join(da.CONFIG_DIR, "config.json")

notifications = []
da.notify_banner = lambda t, s, m, sound=None: notifications.append(("banner", t, m))
da.notify_modal = lambda t, m, url=None: notifications.append(("modal", t, m))
da.play_sound = lambda n: None

FAKE = [
    {"id": 1, "name": "High CPU on prod-web", "overall_state": "Alert", "options": {}},
    {"id": 2, "name": "P95 latency checkout-api", "overall_state": "Alert", "options": {}},
    {"id": 3, "name": "Disk space db-primary", "overall_state": "Warn", "options": {}},
    {"id": 4, "name": "Healthcheck payments svc", "overall_state": "OK", "options": {}},
    {"id": 5, "name": "Kafka consumer lag", "overall_state": "OK",
     "options": {"silenced": {"*": None}}},
    {"id": 6, "name": "Agent reporting (staging)", "overall_state": "No Data", "options": {}},
]

with mock.patch.object(da.DatadogClient, "get_monitors", return_value=FAKE), \
     mock.patch.object(da.DatadogClient, "has_keys", return_value=True):
    app = da.DatadogAssistant()
    # first fetch was kicked off in a thread; wait for it then drain
    for _ in range(50):
        if not app.results.empty(): break
        time.sleep(0.05)
    app._drain_results(None)

    g = app._grouped()
    assert len(g["Alert"]) == 2 and len(g["Warn"]) == 1, g
    assert len(g["Muted"]) == 1 and len(g["No Data"]) == 1, g
    assert app.title == "🚨 2", repr(app.title)
    # first poll: no prev state -> no notifications (avoids spam at launch)
    assert notifications == [], notifications

    # second poll: monitor 4 goes Alert, monitor 1 recovers
    FAKE2 = json.loads(json.dumps(FAKE))
    FAKE2[3]["overall_state"] = "Alert"
    FAKE2[0]["overall_state"] = "OK"
    app._handle_new_monitors(FAKE2)
    kinds = [(k, t) for k, t, m in notifications]
    assert ("banner", "🔴 ALERT — Datadog") in kinds, notifications
    assert ("modal", "🔴 ALERT — Datadog") in kinds, notifications
    assert ("banner", "🟢 Recovered — Datadog") in kinds, notifications

    # menu sanity: has add-monitor, quick links, prefs, quit
    titles = [getattr(i, "title", "---sep---") for i in app.menu if i]
    assert any("➕ Add Monitor" in t for t in titles), titles
    assert any("🔗 Quick Links" in t for t in titles), titles
    assert any("⚙️ Preferences" in t for t in titles), titles
    assert any("🔴 ALERTING (2)" in t for t in titles), titles

    # snooze suppresses notifications
    notifications.clear()
    app._make_snoozer(30)(None)
    assert app.title == "😴", repr(app.title)
    FAKE3 = json.loads(json.dumps(FAKE2))
    FAKE3[2]["overall_state"] = "Alert"  # warn -> alert
    app._handle_new_monitors(FAKE3)
    assert notifications == [], notifications

print("SMOKE TEST PASSED ✅")
