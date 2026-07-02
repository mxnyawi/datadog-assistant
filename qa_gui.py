"""
Extensive headless QA for the Datadog Assistant menu bar GUI.

The app is a macOS rumps app, so it can't render on Linux/CI. This harness
stubs rumps + osascript dialogs + the network, then drives the REAL menu
construction and EVERY callback across a matrix of config and data
combinations, asserting structure, state, notifications, and crash-safety.

Run:  python3 qa_gui.py
"""
import sys, types, os, json, time, tempfile, itertools, traceback
import unittest.mock as mock

# --------------------------------------------------------------------------
# rumps stub (richer than the smoke test: real children + scripted Window)
# --------------------------------------------------------------------------
rumps = types.ModuleType("rumps")

class MenuItem:
    def __init__(self, title, callback=None, key=None):
        self.title, self.callback, self.key, self.state = title, callback, key, 0
        self._children = []
    def add(self, item): self._children.append(item)
    @property
    def children(self): return self._children

class Timer:
    def __init__(self, cb, interval): self.cb, self.interval = cb, interval
    def start(self): pass
    def stop(self): pass

class App:
    def __init__(self, name, title=None, quit_button=None):
        self.name, self.title, self._menu = name, title, []
    @property
    def menu(self): return self._menu
    @menu.setter
    def menu(self, items): self._menu = list(items)

class _Resp:
    def __init__(self, clicked, text): self.clicked, self.text = clicked, text

class Window:
    def __init__(self, title="", message="", default_text="", **kw):
        self.title, self.message, self.default_text = title, message, default_text
    def run(self):
        return WINDOW_RESPONDER(self)

def _default_window_responder(win):
    blob = f"{win.title} {win.message}"
    if "DELETE" in blob:
        return _Resp(True, "DELETE")          # confirm destructive prompts
    return _Resp(True, win.default_text or "qa-value")

WINDOW_RESPONDER = _default_window_responder
rumps.MenuItem, rumps.Timer, rumps.App, rumps.Window = MenuItem, Timer, App, Window
rumps.quit_application = lambda *a, **k: None
rumps.notification = lambda *a, **k: None
sys.modules["rumps"] = rumps

# --------------------------------------------------------------------------
# isolate HOME + import
# --------------------------------------------------------------------------
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp
import datadog_assistant as da
da.CONFIG_DIR = os.path.join(tmp, "cfg")
da.CONFIG_PATH = os.path.join(da.CONFIG_DIR, "config.json")
da.STATE_PATH = os.path.join(da.CONFIG_DIR, "state.json")

# --------------------------------------------------------------------------
# I/O stubs + record sinks
# --------------------------------------------------------------------------
NOTES, OPENS, CALLS, KEYCHAIN, ASK_TEXT, ASK_TEXT_LOG = [], [], [], {}, [], []
ASK_CHOICE = [None]
KEYCHAIN_OK = [True]

da.notify_banner = lambda t, s, m, sound=None: NOTES.append(("banner", t, m))
da.notify_modal = lambda t, m, url=None: NOTES.append(("modal", t, m))
da.play_sound = lambda n: None
da.open_url = lambda u: OPENS.append(u)
da.secret_from_cmd = lambda cmd: ""
da.keychain_get = lambda svc: KEYCHAIN.get(svc, "")
def _kset(svc, val):
    if KEYCHAIN_OK[0]:
        KEYCHAIN[svc] = val
        return True
    return False
da.keychain_set = _kset

def _ask_text(title, message, default="", secure=False, ok="Next"):
    ASK_TEXT_LOG.append(title)
    if ASK_TEXT:
        return ASK_TEXT.pop(0)
    return default if default else "qa"
da.ask_text = _ask_text

def _ask_choice(title, message, choices):
    return ASK_CHOICE[0] if ASK_CHOICE[0] is not None else choices[-1]
da.ask_choice = _ask_choice

# osascript / security / open / launchctl etc. -> no-op success
da.subprocess = mock.MagicMock()
da.subprocess.run.return_value = types.SimpleNamespace(returncode=0, stdout="", stderr="")

# run app's worker threads synchronously for deterministic QA
class _SyncThread:
    def __init__(self, target=None, args=(), kwargs=None, daemon=None):
        self._t, self._a, self._k = target, args, kwargs or {}
    def start(self):
        if self._t:
            self._t(*self._a, **self._k)
da.threading.Thread = _SyncThread

# --------------------------------------------------------------------------
# network data (set per scenario) + action recorders
# --------------------------------------------------------------------------
MON, INC, DASH = [], [], []
SERIES = {"series": [{"pointlist": [[0, 50], [1, 80], [2, 97.2]]}]}
for name, fn in [
    ("get_monitors", lambda self: list(MON)),
    ("get_incidents", lambda self: list(INC)),
    ("list_dashboards", lambda self: list(DASH)),
    ("query_metrics", lambda self, q, window_minutes=60: SERIES),
    ("get_orgs", lambda self: [{"name": "Acme Inc"}]),
    ("mute_monitor", lambda self, mid, hours=None: CALLS.append(("mute", mid, hours)) or {}),
    ("unmute_monitor", lambda self, mid: CALLS.append(("unmute", mid)) or {}),
    ("delete_monitor", lambda self, mid: CALLS.append(("delete", mid)) or {}),
    ("create_monitor", lambda self, n, q, m: CALLS.append(("create", n, q, m)) or {}),
]:
    mock.patch.object(da.DatadogClient, name, fn).start()

# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------
NOW = time.time()

def mixed_monitors():
    return json.loads(json.dumps([
        {"id": 1, "name": "High CPU on prod-web", "overall_state": "Alert",
         "priority": 1, "type": "metric alert",
         "query": "avg(last_5m):avg:system.cpu.user{*} > 90",
         "options": {"thresholds": {"critical": 90}},
         "state": {"groups": {"host:web-1": {"status": "Alert", "last_triggered_ts": NOW - 1380},
                              "host:web-2": {"status": "Alert", "last_triggered_ts": NOW - 900}}}},
        {"id": 2, "name": "P95 latency checkout-api", "overall_state": "Alert", "options": {}},
        {"id": 3, "name": "Disk space db-primary", "overall_state": "Warn", "options": {}},
        {"id": 4, "name": "Healthcheck payments", "overall_state": "OK", "options": {}},
        {"id": 5, "name": "Kafka consumer lag", "overall_state": "OK",
         "options": {"silenced": {"*": None}}},
        {"id": 6, "name": "Agent reporting staging", "overall_state": "No Data",
         "type": "metric alert",
         "query": "avg(last_5m):avg:system.cpu.user{env:staging} > 90",
         "options": {"notify_no_data": True}},
        {"id": 8, "name": "Nightly batch error logs", "overall_state": "No Data",
         "type": "log alert", "options": {"notify_no_data": True}},
        {"id": 7, "name": "High CPU on prod-web", "overall_state": "Alert", "options": {}},
    ]))

def all_ok():
    return [{"id": i, "name": f"svc {i} healthy", "overall_state": "OK", "options": {}}
            for i in range(1, 6)]

def malformed():
    # deliberately missing fields to probe robustness
    return [
        {"id": 1},                                            # no name/state/options
        {"name": "no id", "overall_state": "Alert"},          # no id, no options
        {"id": 3, "name": "weird state", "overall_state": "Banana", "options": {}},
        {"id": 4, "name": "null opts", "overall_state": "Warn", "options": None},
        {"id": 5, "name": "tags not list", "overall_state": "Alert",
         "tags": "team:payments", "options": {}},
    ]

INCIDENTS = [{"public_id": "42", "title": "Checkout down", "severity": "SEV-1",
              "state": "active", "created": ""}]
DASHBOARDS = [{"title": "Payments Overview", "url": "https://x/dash/1"}]

# --------------------------------------------------------------------------
# harness helpers
# --------------------------------------------------------------------------
RESULTS = {"pass": 0, "fail": 0, "errors": []}

def check(cond, label):
    if cond:
        RESULTS["pass"] += 1
    else:
        RESULTS["fail"] += 1
        RESULTS["errors"].append(label)
        print("   ✗ FAIL:", label)

def build_app(overrides=None, monitors=None, incidents=None, dashboards=None,
              state=None, enrich=True):
    """Write a partial config (defaults are merged by load_config), set the
    fake network data, construct the app, and drain the first fetch."""
    global MON, INC, DASH
    MON = mixed_monitors() if monitors is None else monitors
    INC = incidents or []
    DASH = dashboards or []
    base = {"api_key": "k", "app_key": "p"}        # configured in keys mode
    cfg = da.deep_merge(base, overrides or {})
    os.makedirs(da.CONFIG_DIR, exist_ok=True)
    json.dump(cfg, open(da.CONFIG_PATH, "w"))
    if state is not None:
        json.dump(state, open(da.STATE_PATH, "w"))
    elif os.path.exists(da.STATE_PATH):
        os.remove(da.STATE_PATH)
    NOTES.clear(); OPENS.clear(); CALLS.clear(); ASK_TEXT_LOG.clear()
    app = da.DatadogAssistant()
    for _ in range(6):
        app._drain_results(None)
    return app

def walk(items):
    out = []
    for it in items:
        if it is None:
            continue
        out.append(it)
        out.extend(walk(getattr(it, "children", [])))
    return out

def titles(app):
    return [getattr(i, "title", "") for i in walk(app.menu)]

def has(app, sub):
    return any(sub in t for t in titles(app))

def find(app, sub):
    return next((i for i in walk(app.menu) if sub in getattr(i, "title", "")), None)

# ==========================================================================
print("\n=== PHASE A — structural matrix (config × data) ===")

# A1: every combination of the boolean display toggles, on mixed data
axes = {
    "notifications.enabled": [True, False],
    "menu.show_ok_monitors": [True, False],
    "context.show_incidents": [True, False],
    "context.show_sparkline": [True, False],
    "context.auto_dashboard_links": [True, False],
    "no_data_triage.enabled": [True, False],
    "icons.show_count": [True, False],
    "notifications.style": ["banner", "modal", "both"],
}
keys = list(axes)
combos = list(itertools.product(*axes.values()))
print(f"A1: {len(combos)} display-toggle combinations on mixed data")
crashed = 0
for combo in combos:
    ov = {}
    for k, v in zip(keys, combo):
        a, b = k.split(".")
        ov.setdefault(a, {})[b] = v
    try:
        app = build_app(ov, incidents=INCIDENTS, dashboards=DASHBOARDS)
        ts = titles(app)
        assert any("Quit" in t for t in ts)
        assert any("Preferences" in t for t in ts)
        assert any("Refresh now" in t for t in ts)
        assert isinstance(app.title, str) and app.title
        # incidents visibility honors the toggle
        show_inc = ov["context"]["show_incidents"]
        assert has(app, "🔥 INCIDENTS") == show_inc, "incident toggle"
        # OK group visibility honors the toggle
        show_ok = ov["menu"]["show_ok_monitors"]
        assert has(app, "🟢 OK (") == show_ok, "ok toggle"
        # dashboards visibility honors the toggle
        assert has(app, "📊 MY DASHBOARDS") == ov["context"]["auto_dashboard_links"]
        # count in title honors icons.show_count (mixed data has 3 alerts)
        if app.title.startswith("‼️"):
            assert ("‼️ " in app.title) == ov["icons"]["show_count"], (app.title, ov["icons"])
    except Exception as e:
        crashed += 1
        RESULTS["errors"].append(f"A1 combo {dict(zip(keys, combo))}: {e}")
        print("   ✗ CRASH:", dict(zip(keys, combo)), "->", e)
check(crashed == 0, f"A1 crash-free across {len(combos)} combos (crashed={crashed})")

# A2: data-shape scenarios
print("A2: data-shape scenarios")
for label, mons, inc, dash in [
    ("empty", [], [], []),
    ("all OK", all_ok(), [], []),
    ("mixed+incidents+dash", mixed_monitors(), INCIDENTS, DASHBOARDS),
    ("malformed monitors", malformed(), [], []),
    ("huge (300 alerts)", [{"id": i, "name": f"mon {i}", "overall_state": "Alert",
                            "options": {}} for i in range(300)], [], []),
]:
    try:
        app = build_app(monitors=mons, incidents=inc, dashboards=dash)
        check(isinstance(app.title, str) and app.title, f"A2 {label}: title set ({app.title!r})")
        check(has(app, "Quit") and has(app, "Preferences"), f"A2 {label}: core menu present")
    except Exception as e:
        check(False, f"A2 {label}: CRASH {e}")
        traceback.print_exc()

# A3: duplicate monitor names must yield unique menu titles (rumps keys by title)
app = build_app(incidents=INCIDENTS, dashboards=DASHBOARDS)
dup = [t for t in titles(app) if t.startswith("🔴 High CPU on prod-web")]
check(len(dup) == 2 and len(set(dup)) == 2, f"A3 duplicate names disambiguated ({len(dup)} items, {len(set(dup))} unique)")

# A4: empty state has no error row and a friendly OK icon
app = build_app(monitors=[])
check(not has(app, "🔌 Error"), "A4 empty data shows no error row")
check(app.title == "🐶", f"A4 empty data shows OK icon ({app.title!r})")

# A5: auth modes drive the configured-credential error correctly
app = build_app({"api_key": "", "app_key": "", "use_keychain": False})
check(has(app, "🔌 Error") and "No API/APP keys" in (app.last_error or ""),
      "A5 keys mode, no keys -> 'No API/APP keys' error")
app = build_app({"auth": "oauth", "oauth_client_id": "", "api_key": "", "app_key": ""})
check(has(app, "🔌 Error") and "OAuth not connected" in (app.last_error or ""),
      "A5 oauth mode, unconfigured -> 'OAuth not connected' error")
app = build_app({"auth": "oauth", "oauth_client_id": "cid",
                 "oauth_domain": "datadoghq.eu",
                 "oauth_blob": json.dumps({"refresh_token": "r", "client_secret": "s"})})
check(not has(app, "🔌 Error") and app.client.site == "datadoghq.eu",
      "A5 oauth configured -> fetches, region from oauth_domain")

# ==========================================================================
print("\n=== PHASE B — click every menu item (crash-walk) ===")
# A rich config so every section + action exists.
rich = {"jira": {"enabled": True}, "custom_links": [{"name": "🔗 Runbook", "url": "https://r"}]}
mock.patch.object(da.JiraClient, "configured", lambda self: True).start()
mock.patch.object(da.JiraClient, "list_projects", lambda self: [("OPS", "Ops")]).start()
mock.patch.object(da.JiraClient, "whoami", lambda self: {"displayName": "QA", "emailAddress": "qa@x"}).start()
mock.patch.object(da.JiraClient, "project_exists", lambda self, k: True).start()
mock.patch.object(da.JiraClient, "find_open_issue", lambda self, mid: None).start()
mock.patch.object(da.JiraClient, "create_issue",
                  lambda self, mid, n, u, c="", extra_labels=None: "OPS-1").start()
mock.patch.object(da.DatadogAssistant, "_datadog_oauth_browser_flow",
                  lambda self, cid, sec: True).start()
mock.patch.object(da.DatadogAssistant, "_jira_oauth_browser_flow",
                  lambda self, cid, sec: True).start()

app = build_app(rich, incidents=INCIDENTS, dashboards=DASHBOARDS,
                state={"jira_created": {"1": "OPS-9"}})
cbs = [(getattr(i, "title", "?"), i.callback) for i in walk(app.menu)
       if getattr(i, "callback", None) and i.callback is not rumps.quit_application]
print(f"B: invoking {len(cbs)} callbacks")
clicked_ok = 0
for title, cb in cbs:
    try:
        cb(MenuItem(title))     # fake sender
        clicked_ok += 1
    except Exception as e:
        check(False, f"B callback CRASH on {title!r}: {e}")
        traceback.print_exc()
check(clicked_ok == len(cbs), f"B all {len(cbs)} callbacks ran without crashing")

# ==========================================================================
print("\n=== PHASE C — behaviour / flow correctness ===")

# C1 notification style matrix on an OK->Alert transition (P2 so it uses base style)
def transition_notes(style=None, enabled=True, recovery=True, snooze=False,
                     priority=None):
    # priority=None -> default severity rule -> uses the base notification
    # style; priority=1 -> p1 rule (which forces "both") to test overrides.
    ov = {"notifications": {"enabled": enabled, "notify_on_recovery": recovery}}
    if style:
        ov["notifications"]["style"] = style
    app = build_app(ov, monitors=all_ok())
    if snooze:
        app._make_snoozer(30)(None)
    mon = {"id": 1, "name": "svc 1", "overall_state": "OK", "options": {}}
    if priority:
        mon["priority"] = priority
    base = all_ok()
    base[0] = mon
    app._handle_new_monitors(base)            # establish baseline
    NOTES.clear()
    nxt = json.loads(json.dumps(base))
    nxt[0]["overall_state"] = "Alert"
    app._handle_new_monitors(nxt)
    return [k for k, t, m in NOTES]

check(transition_notes("banner") == ["banner"], "C1 style=banner -> banner only")
check(transition_notes("modal") == ["modal"], "C1 style=modal -> modal only")
check(sorted(transition_notes("both")) == ["banner", "modal"], "C1 style=both -> banner+modal")
check(transition_notes("both", enabled=False) == [], "C1 notifications disabled -> silent")
check(transition_notes("both", snooze=True) == [], "C1 snoozed -> silent")
# P1 severity rule forces 'both' even if base style is banner
check(sorted(transition_notes("banner", priority=1)) == ["banner", "modal"],
      "C1 P1 severity rule overrides base style to both")

# C2 recovery notification respects the toggle
app = build_app(monitors=[{"id": 1, "name": "x", "overall_state": "Alert", "options": {}}])
app._handle_new_monitors([{"id": 1, "name": "x", "overall_state": "Alert", "options": {}}])
NOTES.clear()
app._handle_new_monitors([{"id": 1, "name": "x", "overall_state": "OK", "options": {}}])
check(any("Recovered" in t for k, t, m in NOTES), "C2 recovery fires when enabled")
app = build_app({"notifications": {"notify_on_recovery": False}},
                monitors=[{"id": 1, "name": "x", "overall_state": "Alert", "options": {}}])
app._handle_new_monitors([{"id": 1, "name": "x", "overall_state": "Alert", "options": {}}])
NOTES.clear()
app._handle_new_monitors([{"id": 1, "name": "x", "overall_state": "OK", "options": {}}])
check(not any("Recovered" in t for k, t, m in NOTES), "C2 recovery silent when disabled")

# C3 mute / unmute call the API with the right args
app = build_app()
CALLS.clear()
app._make_muter(11, 4)(None)
app._make_muter(12, None)(None)
app._make_unmuter(13)(None)
check(("mute", 11, 4) in CALLS and ("mute", 12, None) in CALLS and ("unmute", 13) in CALLS,
      f"C3 mute/unmute hit the API correctly ({CALLS})")

# C4 delete: confirmed only when the user types DELETE
app = build_app()
CALLS.clear()
WINDOW_RESPONDER_PREV = WINDOW_RESPONDER
app._make_deleter(99, "doomed")(None)            # default responder types DELETE
check(("delete", 99) in CALLS, "C4 delete with DELETE typed -> API called")
CALLS.clear()
globals()["WINDOW_RESPONDER"] = lambda win: _Resp(True, "nope")   # wrong text
# patch the responder the app's Window.run uses
rumps.Window.run = lambda self: _Resp(True, "nope")
app._make_deleter(99, "doomed")(None)
check(("delete", 99) not in CALLS, "C4 delete without DELETE -> API NOT called")
rumps.Window.run = lambda self: _default_window_responder(self)   # restore

# C5 add monitor creates with entered values
app = build_app()
CALLS.clear()
app._add_monitor(None)
check(any(c[0] == "create" for c in CALLS), f"C5 add monitor -> create_monitor called ({CALLS})")

# C6 toggles flip + persist config
app = build_app({"notifications": {"sound": True}})
app._toggle_sound(None)
check(json.load(open(da.CONFIG_PATH))["notifications"]["sound"] is False,
      "C6 toggle sound persists False")
app._toggle_sound(None)
check(json.load(open(da.CONFIG_PATH))["notifications"]["sound"] is True,
      "C6 toggle sound persists True")

# C7 site + interval setters persist
app = build_app()
app._make_site_setter("datadoghq.eu")(None)
check(json.load(open(da.CONFIG_PATH))["site"] == "datadoghq.eu", "C7 site setter persists")
app._make_interval_setter(300)(None)
check(json.load(open(da.CONFIG_PATH))["refresh_seconds"] == 300, "C7 interval setter persists")

# C8 snooze / unsnooze
app = build_app()
app._make_snoozer(60)(None)
check(app.title == "😴" and app.snooze_until > time.time(), "C8 snooze sets title + timer")
app._unsnooze(None)
check(app.snooze_until == 0, "C8 unsnooze clears timer")

# C9 Datadog credentials wizard — keys mode, keychain available
app = build_app()
KEYCHAIN.clear(); KEYCHAIN_OK[0] = True
ASK_TEXT[:] = ["NEWAPIKEY", "NEWAPPKEY"]
app._datadog_setup_flow("keys")
cfg = json.load(open(da.CONFIG_PATH))
check(cfg["auth"] == "keys" and cfg["use_keychain"] is True, "C9 keys wizard sets auth=keys + use_keychain")
check(KEYCHAIN.get("datadog-assistant-api-key") == "NEWAPIKEY"
      and KEYCHAIN.get("datadog-assistant-app-key") == "NEWAPPKEY", "C9 keys stored in Keychain")
check(cfg["api_key"] == "" and cfg["app_key"] == "", "C9 plaintext keys cleared when Keychain wins")
check(any(k == "modal" and "connection test" in t.lower() for k, t, m in NOTES)
      or any("Datadog connection" in t for k, t, m in NOTES), "C9 keys wizard runs a connection test")

# C9b keys mode, keychain UNavailable -> falls back to config
app = build_app()
KEYCHAIN.clear(); KEYCHAIN_OK[0] = False
ASK_TEXT[:] = ["CFGAPI", "CFGAPP"]
app._datadog_setup_flow("keys")
cfg = json.load(open(da.CONFIG_PATH))
check(cfg["api_key"] == "CFGAPI" and cfg["app_key"] == "CFGAPP",
      "C9b keychain unavailable -> keys stored in config")
KEYCHAIN_OK[0] = True

# C9c keys wizard cancel (ask_text returns None) leaves auth untouched
app = build_app({"auth": "oauth"})
ASK_TEXT[:] = [None]
app._datadog_setup_flow("keys")
check(json.load(open(da.CONFIG_PATH))["auth"] == "oauth", "C9c cancel on first field aborts (auth unchanged)")

# C10 credentials wizard — oauth mode, browser flow succeeds / fails
app = build_app({"auth": "keys"})
ASK_TEXT[:] = ["client-id", "client-secret"]
with mock.patch.object(da.DatadogAssistant, "_datadog_oauth_browser_flow",
                       lambda self, cid, sec: True):
    app._datadog_setup_flow("oauth")
check(json.load(open(da.CONFIG_PATH))["auth"] == "oauth", "C10 oauth wizard success -> auth=oauth")
app = build_app({"auth": "keys"})
ASK_TEXT[:] = ["client-id", "client-secret"]
with mock.patch.object(da.DatadogAssistant, "_datadog_oauth_browser_flow",
                       lambda self, cid, sec: False):
    app._datadog_setup_flow("oauth")
check(json.load(open(da.CONFIG_PATH))["auth"] == "keys",
      "C10 oauth wizard failure -> auth left unchanged")

# C11 chooser dispatch (ask_choice) routes to the right flow
routed = []
app = build_app()
with mock.patch.object(da.DatadogAssistant, "_datadog_setup_flow",
                       lambda self, mode: routed.append(mode)):
    ASK_CHOICE[0] = "API + App keys"; app._datadog_setup()
    ASK_CHOICE[0] = "OAuth"; app._datadog_setup()
    ASK_CHOICE[0] = "Cancel"; app._datadog_setup()
ASK_CHOICE[0] = None
check(routed == ["keys", "oauth"], f"C11 chooser routes keys/oauth, Cancel aborts ({routed})")

# C12 Datadog connection test: configured vs not
app = build_app()
NOTES.clear(); app._datadog_connection_test()
check(any("connection test" in t.lower() and "Fetched" in m for k, t, m in NOTES),
      f"C12 connection test (configured) reports fetched monitors ({NOTES})")
app = build_app({"api_key": "", "app_key": ""})
NOTES.clear(); app._datadog_connection_test()
check(any("not configured" in t.lower() for k, t, m in NOTES),
      f"C12 connection test (unconfigured) says not configured ({NOTES})")

# C13 Jira wizard — token mode end to end
app = build_app({"jira": {"enabled": False}})
ASK_TEXT[:] = ["https://co.atlassian.net", "me@co.com", "tok123",  # creds
               "OPS", "Task", "team-x"]                            # ticket fields
with mock.patch.object(da.JiraClient, "list_projects", lambda self: [("OPS", "Ops")]):
    app._jira_setup_flow("token")
cfg = json.load(open(da.CONFIG_PATH))["jira"]
check(cfg["auth"] == "token" and cfg["enabled"] is True and cfg["project_key"] == "OPS",
      f"C13 jira token wizard configures + enables ({cfg.get('auth')}, {cfg.get('enabled')})")
check(KEYCHAIN.get("datadog-assistant-jira-token") == "tok123", "C13 jira token stored in Keychain")

# C14 Jira toggle on when already configured
app = build_app({"jira": {"enabled": False}})
NOTES.clear()
app._toggle_jira(None)        # JiraClient.configured patched True earlier
check(json.load(open(da.CONFIG_PATH))["jira"]["enabled"] is True, "C14 jira toggle enables when configured")

# C15 transient API error must not hide a known alert state
app = build_app()
app.results.put(("error", "HTTP 503 from Datadog API"))
app._drain_results(None)
check(app.title != "🔌", f"C15 error after data keeps alert title ({app.title!r})")
check(has(app, "🔌 Error"), "C15 error still shown as a menu row")

# ==========================================================================
print("\n" + "=" * 60)
print(f"QA RESULTS:  {RESULTS['pass']} passed, {RESULTS['fail']} failed")
if RESULTS["fail"]:
    print("\nFailures:")
    for e in RESULTS["errors"]:
        print("  -", e)
    sys.exit(1)
print("ALL GUI QA CHECKS PASSED ✅")
