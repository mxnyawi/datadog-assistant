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

import unittest.mock as mock

# ---- isolate config dir ----
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp

import datadog_assistant as da
da.CONFIG_DIR = os.path.join(tmp, "cfg")
da.CONFIG_PATH = os.path.join(da.CONFIG_DIR, "config.json")
da.STATE_PATH = os.path.join(da.CONFIG_DIR, "state.json")

notifications = []
da.notify_banner = lambda t, s, m, sound=None: notifications.append(("banner", t, m))
da.notify_modal = lambda t, m, url=None: notifications.append(("modal", t, m))
da.play_sound = lambda n: None

# ---- pure helper units ----
assert da.parse_priority({"priority": 1}) == 1
assert da.parse_priority({"tags": ["env:prod", "priority:p2"]}) == 2
assert da.parse_priority({"name": "[P3] disk space"}) == 3
assert da.parse_priority({"name": "no priority"}) is None
assert da.extract_metric_query(
    "avg(last_5m):avg:system.cpu.user{env:prod} by {host} > 90") == \
    "avg:system.cpu.user{env:prod} by {host}"
assert da.extract_metric_query("logs query weird") == ""
assert da.sparkline([1, 2, 3, 8]) == "▁▂▃█"
assert da.fmt_duration(125) == "2m"
assert da.fmt_duration(7300) == "2h 01m"
assert da.fmt_num(97.234) == "97.23"
assert da.fmt_num(125000) == "125,000"

NOW = time.time()
FAKE = [
    {"id": 1, "name": "High CPU on prod-web", "overall_state": "Alert",
     "priority": 1, "type": "metric alert",
     "query": "avg(last_5m):avg:system.cpu.user{*} > 90",
     "options": {"thresholds": {"critical": 90}},
     "state": {"groups": {"host:web-1": {"status": "Alert",
                                         "last_triggered_ts": NOW - 1380},
                          "host:web-2": {"status": "Alert",
                                         "last_triggered_ts": NOW - 900}}}},
    {"id": 2, "name": "P95 latency checkout-api", "overall_state": "Alert",
     "options": {}},
    {"id": 3, "name": "Disk space db-primary", "overall_state": "Warn", "options": {}},
    {"id": 4, "name": "Healthcheck payments svc", "overall_state": "OK", "options": {}},
    {"id": 5, "name": "Kafka consumer lag", "overall_state": "OK",
     "options": {"silenced": {"*": None}}},
    # broken No Data: wants no-data alerts + probe sees the metric flowed then stopped
    {"id": 6, "name": "Agent reporting (staging)", "overall_state": "No Data",
     "type": "metric alert",
     "query": "avg(last_5m):avg:system.cpu.user{env:staging} > 90",
     "options": {"notify_no_data": True}},
    # quiet No Data: event-stream monitor — zero matching logs is normal
    {"id": 8, "name": "Nightly batch error logs", "overall_state": "No Data",
     "type": "log alert", "options": {"notify_no_data": True}},
]
FAKE_INCIDENTS = [{"public_id": "42", "title": "Checkout down", "severity": "SEV-1",
                   "state": "active", "created": ""}]
FAKE_DASHBOARDS = [{"title": "Payments Overview", "url": "https://x/dash/1"}]
FAKE_SERIES = {"series": [{"pointlist": [[0, 50], [1, 80], [2, 97.2]]}]}

with mock.patch.object(da.DatadogClient, "get_monitors", return_value=FAKE), \
     mock.patch.object(da.DatadogClient, "get_incidents", return_value=FAKE_INCIDENTS), \
     mock.patch.object(da.DatadogClient, "list_dashboards", return_value=FAKE_DASHBOARDS), \
     mock.patch.object(da.DatadogClient, "query_metrics", return_value=FAKE_SERIES), \
     mock.patch.object(da.DatadogClient, "has_keys", return_value=True):
    app = da.DatadogAssistant()
    for _ in range(50):
        if not app.results.empty(): break
        time.sleep(0.05)
    app._drain_results(None)

    g = app._grouped()
    assert len(g["Alert"]) == 2 and len(g["Warn"]) == 1, g
    assert len(g["Muted"]) == 1 and len(g["No Data"]) == 1, g
    # no-data triage: probe saw data then silence -> broken; log alert -> quiet
    assert len(g["Quiet"]) == 1 and g["Quiet"][0]["id"] == 8, g
    assert g["No Data"][0]["id"] == 6, g
    v, r = app._triage_no_data(FAKE[5])
    assert v == "broken" and "stopped" in r, (v, r)
    v, r = app._triage_no_data(FAKE[6])
    assert v == "quiet" and "event-stream" in r, (v, r)
    v, r = app._triage_no_data({"id": 9, "overall_state": "No Data",
                                "type": "metric alert", "options": {}})
    assert v == "quiet" and "off" in r, (v, r)        # author opted out
    v, r = app._triage_no_data(
        {"id": 10, "overall_state": "No Data", "type": "metric alert",
         "options": {"notify_no_data": True},
         "state": {"groups": {"host:old": {"status": "No Data",
                                           "last_nodata_ts": NOW - 3 * 86400}}}})
    assert v == "quiet" and "retired" in r, (v, r)    # stale for days
    # P1 alert present -> severity icon from p1 rule
    assert app.title == "‼️ 2", repr(app.title)
    # first poll: no prev state -> no notifications (avoids spam at launch)
    assert notifications == [], notifications

    # enrichment + context line for the P1 monitor
    e = app.enrich.get(1)
    assert e and e["spark"] and e["now"] == 97.2 and e["crit"] == 90, e
    ctx = app._context_line(FAKE[0])
    assert "P1" in ctx and "⏱ 23m" in ctx and "2 groups" in ctx \
        and "97.2 (crit 90)" in ctx, ctx

    # menu: incidents section + enriched monitor submenu
    titles = [getattr(i, "title", None) for i in app.menu if i]
    assert any("🔥 INCIDENTS (1)" in t for t in titles), titles
    assert any("SEV-1" in t for t in titles), titles
    mon_item = next(i for i in app.menu
                    if i and getattr(i, "title", "").startswith("🔴 High CPU"))
    sub = [c.title for c in mon_item.children if c]
    assert any("Priority P1" in t for t in sub), sub
    assert any("📈" in t and "97.2" in t for t in sub), sub
    assert any("host:web-1" in t for t in sub), sub
    # dashboards inside quick links
    ql = next(i for i in app.menu if i and "Quick Links" in getattr(i, "title", ""))
    qsub = [c.title for c in ql.children if c]
    assert any("Payments Overview" in t for t in qsub), qsub

    # second poll: monitor 4 goes Alert, monitor 1 recovers
    FAKE2 = json.loads(json.dumps(FAKE))
    FAKE2[3]["overall_state"] = "Alert"
    FAKE2[0]["overall_state"] = "OK"
    app._handle_new_monitors(FAKE2)
    kinds = [(k, t) for k, t, m in notifications]
    assert ("banner", "🔴 ALERT — Datadog") in kinds, notifications
    assert ("modal", "🔴 ALERT — Datadog") in kinds, notifications
    assert ("banner", "🟢 Recovered — Datadog") in kinds, notifications

    # triage gates No Data notifications: broken notifies (with the reason),
    # quiet stays silent
    base = json.loads(json.dumps(FAKE2))
    base[3]["overall_state"] = "OK"
    base[5]["overall_state"] = "OK"
    base[6]["overall_state"] = "OK"
    app._handle_new_monitors(base)            # baseline: everything calm
    notifications.clear()
    nd = json.loads(json.dumps(base))
    nd[5]["overall_state"] = "No Data"        # broken (probe: stopped)
    nd[6]["overall_state"] = "No Data"        # quiet (log alert)
    app._handle_new_monitors(nd)
    nd_msgs = [m for k, t, m in notifications if "No Data" in t]
    assert nd_msgs and all("Agent reporting" in m for m in nd_msgs), notifications
    assert all("stopped" in m for m in nd_msgs), notifications
    assert not any("Nightly batch" in m for k, t, m in notifications), notifications

    # P1 renotify: pretend last notice was 11 min ago (p1 rule = 10 min)
    notifications.clear()
    FAKE3 = json.loads(json.dumps(FAKE2))
    FAKE3[0]["overall_state"] = "Alert"
    app._handle_new_monitors(FAKE3)          # OK -> Alert transition
    notifications.clear()
    app.last_notified[1] = time.time() - 11 * 60
    app._handle_new_monitors(FAKE3)          # still alerting
    assert any("STILL ALERTING" in t for k, t, m in notifications), notifications
    # banner body carries the severity context
    body = next(m for k, t, m in notifications if k == "banner")
    assert "P1" in body, body

    # jira: manual create with dedupe miss -> issue created
    created = {}
    with mock.patch.object(da.JiraClient, "configured", return_value=True), \
         mock.patch.object(da.JiraClient, "find_open_issue", return_value=None), \
         mock.patch.object(da.JiraClient, "create_issue",
                           side_effect=lambda mid, n, u, c: created.update(
                               {"mid": mid, "ctx": c}) or "OPS-7"):
        app.cfg["jira"]["enabled"] = True
        notifications.clear()
        app._create_jira(FAKE3[0])
        time.sleep(0.3)
        assert created["mid"] == 1 and "P1" in created["ctx"], created
        assert app.state["jira_created"]["1"] == "OPS-7"
        assert any("OPS-7" in m for k, t, m in notifications), notifications
        # auto-create respects max priority (P3 monitor -> no ticket)
        app.cfg["jira"]["auto_create"] = True
        app._maybe_auto_jira({"id": 9, "name": "x", "priority": 3})
        time.sleep(0.2)
        assert "9" not in app.state.get("jira_created", {})

    # duplicate monitor names must NOT collide (rumps keys menus by title)
    FAKE_DUP = json.loads(json.dumps(FAKE3))
    FAKE_DUP.append({"id": 7, "name": "High CPU on prod-web",
                     "overall_state": "Alert", "options": {}})
    app._handle_new_monitors(FAKE_DUP)
    app._rebuild_menu()
    dup_titles = [getattr(i, "title", "") for i in app.menu
                  if i and getattr(i, "title", "").startswith("🔴 High CPU")]
    assert len(dup_titles) == 2 and len(set(dup_titles)) == 2, dup_titles

    # fingerprint: same data -> no rebuild, only the timestamp row updates
    app._handle_new_monitors(FAKE_DUP)
    fp1 = app._menu_fingerprint()
    assert fp1 == app._menu_fp, "fingerprint should be stable on same data"
    marker = rumps.MenuItem("marker")
    app.menu.append(marker)
    app.results.put(("data", {"monitors": FAKE_DUP, "enrich": dict(app.enrich)}))
    app._drain_results(None)
    assert marker in app.menu, "menu must not rebuild when nothing changed"
    assert "Refresh now" in app._refresh_item.title
    # ...but a state change does rebuild
    FAKE_CHG = json.loads(json.dumps(FAKE_DUP))
    FAKE_CHG[5]["overall_state"] = "OK"   # No Data -> OK
    app.results.put(("data", {"monitors": FAKE_CHG, "enrich": dict(app.enrich)}))
    app._drain_results(None)
    assert marker not in app.menu, "menu should rebuild on state change"

    # transient API error must not hide alert state in the title
    app.results.put(("error", "HTTP 503 from Datadog API"))
    app._drain_results(None)
    assert app.title != "🔌", repr(app.title)
    titles = [getattr(i, "title", "") for i in app.menu if i]
    assert any("🔌 Error" in t for t in titles), titles
    assert any("📊" in t for t in titles), "summary should still show"
    app.last_error = None

    # unique_title helper
    s = set()
    a, b = da.unique_title("x", s), da.unique_title("x", s)
    assert a != b and b.startswith("x"), (a, b)

    # snooze suppresses notifications
    notifications.clear()
    app._make_snoozer(30)(None)
    assert app.title == "😴", repr(app.title)
    FAKE4 = json.loads(json.dumps(FAKE3))
    FAKE4[2]["overall_state"] = "Alert"  # warn -> alert
    app._handle_new_monitors(FAKE4)
    assert notifications == [], notifications

print("SMOKE TEST PASSED ✅")
