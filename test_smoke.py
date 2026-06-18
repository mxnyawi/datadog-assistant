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

# Jira error bodies surface the actual field problem
fake_err = types.SimpleNamespace(
    read=lambda: json.dumps({"errorMessages": ["boom"],
                             "errors": {"issuetype": "invalid"}}).encode(),
    reason="Bad Request")
assert da.http_error_detail(fake_err) == "boom; issuetype: invalid"
fake_err2 = types.SimpleNamespace(read=lambda: b"<html>", reason="Bad Request")
assert da.http_error_detail(fake_err2) == "Bad Request"

# password-manager secret commands: stdout is the secret, failures retry
assert da.secret_from_cmd("echo  s3cret ") == "s3cret"
assert da.secret_from_cmd("exit 3") == ""          # failure -> empty, uncached
assert "exit 3" not in da._SECRET_CMD_CACHE
assert "echo  s3cret " in da._SECRET_CMD_CACHE     # success cached
dd = da.DatadogClient({"api_key": "cfgkey", "app_key": "cfgapp",
                       "api_key_cmd": "echo vaultkey"})
assert dd._keys() == ("vaultkey", "cfgapp")        # cmd wins over config
jt = da.JiraClient({"api_token": "cfgtok", "api_token_cmd": "echo vaulttok"})
assert jt._token() == "vaulttok"

# OAuth-mode Jira client hits api.atlassian.com with a Bearer token
import io
oauth_jc = da.JiraClient({"auth": "oauth", "cloud_id": "abc123",
                          "oauth_client_id": "cid"})
oauth_jc._access = {"token": "tok", "expires": time.time() + 3600}
captured = {}

def fake_urlopen(req, timeout=None):
    captured["url"] = req.full_url
    captured["auth"] = req.get_header("Authorization")
    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass
    return R(b'{"ok": true}')

with mock.patch.object(da.urllib.request, "urlopen", fake_urlopen):
    out = oauth_jc._request("GET", "/rest/api/3/myself")
assert out == {"ok": True}, out
assert captured["url"] == \
    "https://api.atlassian.com/ex/jira/abc123/rest/api/3/myself", captured
assert captured["auth"] == "Bearer tok", captured

# OAuth-mode Datadog client: Bearer token + region taken from oauth_domain
dd_oauth = da.DatadogClient({"auth": "oauth", "oauth_client_id": "cid",
                             "oauth_domain": "datadoghq.eu",
                             "site": "datadoghq.com"})
dd_oauth._access = {"token": "ddtok", "expires": time.time() + 3600}
assert dd_oauth.auth_mode() == "oauth"
assert dd_oauth.site == "datadoghq.eu"            # oauth domain wins over site
cap_dd = {}

def fake_urlopen_dd(req, timeout=None):
    cap_dd["url"] = req.full_url
    cap_dd["auth"] = req.get_header("Authorization")
    cap_dd["ddkey"] = req.get_header("Dd-api-key")  # must NOT be sent in oauth
    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass
        headers = {}
    return R(b"[]")

with mock.patch.object(da.urllib.request, "urlopen", fake_urlopen_dd):
    dd_oauth._request("GET", "/monitor")
assert cap_dd["url"].startswith("https://api.datadoghq.eu/api/v1/monitor"), cap_dd
assert cap_dd["auth"] == "Bearer ddtok", cap_dd
assert cap_dd["ddkey"] is None, cap_dd

# configured(): keys-mode falls back to has_keys; oauth needs a refresh token
assert da.DatadogClient({"api_key": "a", "app_key": "b"}).configured() is True
assert da.DatadogClient(
    {"auth": "oauth", "oauth_client_id": "cid"}).configured() is False
# key-mode client still uses DD-API-KEY headers (no regression)
cap_k = {}

def fake_urlopen_k(req, timeout=None):
    cap_k["auth"] = req.get_header("Authorization")
    cap_k["ddkey"] = req.get_header("Dd-api-key")
    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass
        headers = {}
    return R(b"[]")

with mock.patch.object(da.urllib.request, "urlopen", fake_urlopen_k):
    da.DatadogClient({"api_key": "k", "app_key": "p"})._request("GET", "/monitor")
assert cap_k["auth"] is None and cap_k["ddkey"] == "k", cap_k

# OAuth refresh: hits the regional token endpoint (form-encoded), caches the
# access token, and rotates the refresh token back into the stored blob
dd_ref = da.DatadogClient({
    "auth": "oauth", "oauth_client_id": "cid", "oauth_domain": "datadoghq.eu",
    "oauth_blob": json.dumps({"client_secret": "sek", "refresh_token": "r1"})})
ref_cap = {}

def fake_urlopen_ref(req, timeout=None):
    ref_cap["url"] = req.full_url
    ref_cap["ctype"] = req.get_header("Content-type")
    ref_cap["body"] = req.data.decode()
    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass
    return R(json.dumps({"access_token": "AT", "expires_in": 3600,
                         "refresh_token": "r2"}).encode())

with mock.patch.object(da.urllib.request, "urlopen", fake_urlopen_ref):
    assert dd_ref._access_token() == "AT"
assert ref_cap["url"] == "https://api.datadoghq.eu/oauth2/v1/token", ref_cap
assert ref_cap["ctype"] == "application/x-www-form-urlencoded", ref_cap
assert "grant_type=refresh_token" in ref_cap["body"], ref_cap
assert "refresh_token=r1" in ref_cap["body"], ref_cap
# rotated refresh token persisted (Keychain unavailable here -> cfg fallback)
assert dd_ref._oauth_blob().get("refresh_token") == "r2", dd_ref._oauth_blob()
# cached: a second call doesn't hit the network again
assert dd_ref._access_token() == "AT"

# create_issue merges cfg labels + per-monitor labels + dd-monitor-<id>, deduped
cap = {}

def fake_urlopen2(req, timeout=None):
    cap["body"] = json.loads(req.data.decode())
    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass
    return R(b'{"key": "OPS-9"}')

jc2 = da.JiraClient({"base_url": "https://x.atlassian.net", "email": "e",
                     "api_token": "t", "labels": ["datadog-alert"]})
with mock.patch.object(da.urllib.request, "urlopen", fake_urlopen2):
    k = jc2.create_issue(5, "mon", "https://dd/x", "",
                         ["datadog-alert-team-payments", "datadog-alert"])
assert k == "OPS-9"
assert cap["body"]["fields"]["labels"] == \
    ["datadog-alert", "datadog-alert-team-payments", "dd-monitor-5"], cap

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

    # labels derived from monitor tags: datadog-alert-<tag>
    assert da.jira_label("team:payments") == "team-payments"
    assert da.jira_label("env: prod ") == "env-prod"
    tagged = {"id": 1, "tags": ["team:payments", "env:prod"]}
    assert app._monitor_auto_labels(tagged) == \
        ["datadog-alert-team-payments", "datadog-alert-env-prod"], \
        app._monitor_auto_labels(tagged)
    app.cfg["tag_filter"] = "team:payments"          # filter narrows labels
    assert app._monitor_auto_labels(tagged) == ["datadog-alert-team-payments"]
    app.cfg["tag_filter"] = ""
    app.cfg["jira"]["auto_label_from_tags"] = False  # opt-out
    assert app._monitor_auto_labels(tagged) == []
    app.cfg["jira"]["auto_label_from_tags"] = True

    # jira: manual create with dedupe miss -> issue created
    created = {}
    with mock.patch.object(da.JiraClient, "configured", return_value=True), \
         mock.patch.object(da.JiraClient, "find_open_issue", return_value=None), \
         mock.patch.object(da.JiraClient, "create_issue",
                           side_effect=lambda mid, n, u, c, extra=None: created.update(
                               {"mid": mid, "ctx": c, "extra": extra}) or "OPS-7"):
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

    # ---- local renames ----
    app.state.setdefault("aliases", {})["1"] = "💳 Payments CPU"
    assert app._display_name(FAKE[0]) == "💳 Payments CPU"
    assert app._display_name(FAKE[1]) == "P95 latency checkout-api"  # unaliased
    app.monitors = json.loads(json.dumps(FAKE))
    app.snooze_until = 0
    app._rebuild_menu()
    titles = [getattr(i, "title", "") for i in app.menu if i]
    assert any("💳 Payments CPU" in t for t in titles), titles
    assert not any("High CPU on prod-web" in t for t in titles), titles
    # rename feeds notifications + fingerprint
    assert "💳 Payments CPU" in str(app._menu_fingerprint())
    # reset restores the Datadog name
    app._make_alias_resetter(1)(None)
    assert "1" not in app.state.get("aliases", {})
    titles = [getattr(i, "title", "") for i in app.menu if i]
    assert any("High CPU on prod-web" in t for t in titles), titles

    # ---- DLQ grouping ----
    DLQ = [
        {"id": 101, "name": "payments-dlq depth", "overall_state": "Alert",
         "options": {}},
        {"id": 102, "name": "orders DLQ age", "overall_state": "OK",
         "options": {}},
        {"id": 103, "name": "billing backlog", "overall_state": "Warn",
         "options": {},
         "query": "sum(last_5m):sum:sqs.dead_letter.messages{*} > 1"},
        {"id": 104, "name": "shipping queue", "overall_state": "OK",
         "options": {}, "tags": ["queue:deadletter"]},
        {"id": 105, "name": "regular cpu", "overall_state": "Alert",
         "options": {}},
    ]
    assert [app._is_dlq(m) for m in DLQ] == [True, True, True, True, False]
    # alias can also tip a monitor into the DLQ bucket
    app.state.setdefault("aliases", {})["105"] = "orders DLQ retries"
    assert app._is_dlq(DLQ[4]) is True
    app.state["aliases"].pop("105")

    app.monitors = DLQ
    app.enrich = {}
    app._rebuild_menu()
    dlq = app._dlq_monitors()
    assert [m["id"] for m in dlq] == [101, 103, 102, 104], dlq  # severity-sorted
    titles = [getattr(i, "title", "") for i in app.menu if i]
    assert any(t.startswith("💀 DEAD LETTER QUEUES (4)") and "1 alerting" in t
               for t in titles), titles
    # exclusive: DLQ alert is pulled out of the ALERTING group (only 105 left)
    assert any("🔴 ALERTING (1)" == t for t in titles), titles
    # healthy DLQs collapse into a submenu
    healthy = next(i for i in app.menu
                   if i and getattr(i, "title", "").startswith("🟢 healthy"))
    assert "(2)" in healthy.title, healthy.title
    assert {c.title.split(" ", 1)[1].split(" age")[0].split(" queue")[0]
            for c in healthy.children if c} == {"orders DLQ", "shipping"}, \
        [c.title for c in healthy.children]
    # summary advertises the DLQ count
    assert any("💀 4 dlq" in t for t in titles), titles

    # toggle DLQ grouping off -> section gone, DLQ alert back in ALERTING (2)
    app._toggle_dlq(None)
    titles = [getattr(i, "title", "") for i in app.menu if i]
    assert not any("DEAD LETTER" in t for t in titles), titles
    assert any("🔴 ALERTING (2)" == t for t in titles), titles
    app._toggle_dlq(None)  # restore

    # ---- GitHub: service→repo resolver ----
    app.cfg["github"]["default_org"] = ""
    app.cfg["github"]["repo_map"] = {"service:billing": "myorg/billing",
                                     "checkout": "myorg/checkout"}
    app.state.pop("repos", None)
    assert app._repo_for({"id": 2, "tags": ["service:billing"]}) == "myorg/billing"
    assert app._repo_for({"id": 3, "name": "Checkout p95"}) == "myorg/checkout"
    assert app._repo_for({"id": 4, "tags": ["repo:acme/widgets"]}) == "acme/widgets"
    assert app._repo_for({"id": 5, "name": "nothing", "tags": []}) is None
    app.cfg["github"]["default_org"] = "myorg"
    assert app._repo_for({"id": 6, "tags": ["service:payments"]}) == "myorg/payments"
    # an explicit per-monitor link beats every mapping rule
    app.state.setdefault("repos", {})["2"] = "myorg/override"
    assert app._repo_for({"id": 2, "tags": ["service:billing"]}) == "myorg/override"
    app.state["repos"].pop("2")

    # ---- GitHub: correlation + menu render ----
    gmon = {"id": 1, "name": "checkout latency", "overall_state": "Alert",
            "tags": ["service:payments"], "options": {},
            "state": {"groups": {"host:a": {"status": "Alert",
                                            "last_triggered_ts": NOW - 1380}}}}
    app.cfg["github"].update({"enabled": True, "token": "x",
                              "default_org": "myorg", "repo_map": {}})
    app.github = da.GitHubClient(app.cfg["github"])
    assert app.github.configured()
    assert app.github.web_base() == "https://github.com"
    astart = time.time() - app._alert_duration(gmon)
    app.github.recent_deployments = lambda repo, envs, limit=10: [
        {"env": "production", "ref": "main", "sha": "abc1234", "creator": "alice",
         "when": astart - 600, "state": "success",
         "url": "https://github.com/myorg/payments/deployments"}]
    app.github.latest_release = lambda repo: {
        "tag": "v2.3.1", "name": "v2.3.1", "when": NOW - 7200,
        "url": "https://github.com/myorg/payments/releases/tag/v2.3.1"}
    app.github.recent_runs = lambda repo, since, limit=4: [
        {"name": "deploy", "status": "completed", "conclusion": "success",
         "branch": "main", "event": "push", "when": NOW - 800,
         "url": "https://github.com/x/runs/1"}]
    app.github.recent_commits = lambda repo, since, limit=4: [
        {"sha": "abc1234", "msg": "bump timeout", "author": "alice",
         "when": astart - 600, "url": "https://github.com/x/commit/abc1234"}]

    app.monitors = [gmon]
    ghmap = app._fetch_github([gmon])
    ctx = ghmap[1]
    assert "Deployed to production" in ctx["headline"], ctx
    assert "before this alert" in ctx["headline"], ctx
    assert ctx["repo"] == "myorg/payments", ctx
    assert ctx["suspect_url"].endswith("/deployments"), ctx

    app.gh = ghmap
    app._rebuild_menu()
    mi = next(i for i in app.menu
              if i and getattr(i, "title", "").startswith("🔴 checkout"))
    labels = [c.title for c in mi.children if c]
    assert any("Deployed to production" in t for t in labels), labels
    ghsub = next(c for c in mi.children
                 if c and getattr(c, "title", "").startswith("🐙 myorg/payments"))
    gl = [c.title for c in ghsub.children if c]
    assert any("Recent deploys" in t for t in gl), gl
    assert any("production" in t and "abc1234" in t for t in gl), gl
    assert any("v2.3.1" in t for t in gl), gl
    assert any("bump timeout" in t for t in gl), gl
    # gh signature is part of the fingerprint -> menu repaints on new gh data
    assert ctx["sig"] in str(app._menu_fingerprint())

    # everything older than the correlation window -> NO scary headline,
    # but the panel (deploys/commits) still renders for manual inspection
    old = NOW - 5 * 86400
    app.github.recent_deployments = lambda repo, envs, limit=10: [
        {"env": "production", "ref": "main", "sha": "old0000", "creator": "bob",
         "when": old, "state": "success", "url": "https://x/d"}]
    app.github.latest_release = lambda repo: {
        "tag": "v1.0", "name": "v1.0", "when": old, "url": "https://x/r"}
    app.github.recent_runs = lambda repo, since, limit=4: []
    app.github.recent_commits = lambda repo, since, limit=4: [
        {"sha": "old0000", "msg": "ancient", "author": "bob",
         "when": old, "url": "https://x/c"}]
    app._gh_cache.clear()
    ctx2 = app._fetch_github([gmon])[1]
    assert ctx2["headline"] is None, ctx2
    assert ctx2["raw"]["deploys"], ctx2  # data still present

    # ---- GitHub: correlation hint rides along on the alert notification ----
    app.gh = {77: {"headline": "🚀 Deployed to production 5m before this alert",
                   "sig": "x", "repo": "myorg/x", "raw": {}}}
    app.cfg["github"]["notify_correlation"] = True
    app.snooze_until = 0
    notifications.clear()
    app.prev_states[77] = "OK"
    app._handle_new_monitors([{"id": 77, "name": "svc", "overall_state": "Alert",
                               "options": {}}])
    assert any("Deployed to production" in m for k, t, m in notifications), \
        notifications

    # ---- GitHub OAuth: URLs, mode, bearer, configured ----
    ghc = da.GitHubClient({"auth": "oauth", "api_base": "https://api.github.com"})
    assert ghc.auth_mode() == "oauth"
    assert ghc.oauth_authorize_url() == "https://github.com/login/oauth/authorize"
    assert ghc.oauth_token_url() == "https://github.com/login/oauth/access_token"
    ghe = da.GitHubClient({"auth": "oauth",
                           "api_base": "https://ghe.acme.com/api/v3"})
    assert ghe.web_base() == "https://ghe.acme.com", ghe.web_base()
    assert ghe.oauth_authorize_url() == \
        "https://ghe.acme.com/login/oauth/authorize"
    # non-expiring OAuth token from the Keychain blob
    ghc._oauth_blob = lambda: {"access_token": "gho_live"}
    assert ghc.configured() is True
    assert ghc._bearer() == "gho_live"
    # token mode is unaffected and still works
    tc = da.GitHubClient({"auth": "token", "token": "pat_x"})
    assert tc.configured() and tc._bearer() == "pat_x"
    assert da.GitHubClient({"auth": "oauth"}).configured() is False

    # ---- GitHub auto-discovery: code-search a monitor → repo ----
    app.cfg["github"].update({"enabled": True, "auth": "token", "token": "x",
                              "default_org": "myorg", "repo_map": {},
                              "auto_discover": True})
    app.github = da.GitHubClient(app.cfg["github"])
    app.github.search_code = lambda q, per_page=5: (
        [{"repository": {"full_name": "myorg/payments-api"}}]
        if "checkout latency" in q else [])
    assert app.github.repo_for_monitor("checkout latency", 1, "myorg") == \
        "myorg/payments-api"
    assert app.github.repo_for_monitor("unknown thing", 2, "myorg") is None

    app.state.pop("repos", None)
    app.state.pop("repos_auto", None)
    dmon = {"id": 555, "name": "checkout latency", "overall_state": "Alert",
            "tags": [], "options": {}}
    app._discover_repos([dmon], {"Alert", "Warn", "No Data"})
    assert app.state["repos_auto"]["555"]["repo"] == "myorg/payments-api"
    assert app._repo_for(dmon) == "myorg/payments-api"
    assert app._repo_source(dmon) == "auto"
    # a manual link beats an auto-detected one
    app.state.setdefault("repos", {})["555"] = "myorg/manual"
    assert app._repo_for(dmon) == "myorg/manual"
    assert app._repo_source(dmon) == "manual"
    app.state["repos"].pop("555")
    # a not-found search is cached as a miss (no repeat search until TTL)
    nmon = {"id": 556, "name": "unknown thing", "overall_state": "Alert",
            "tags": [], "options": {}}
    app._discover_repos([nmon], {"Alert", "Warn", "No Data"})
    assert app.state["repos_auto"]["556"]["repo"] == ""
    assert app._repo_for(nmon) is None

    # auto-detected repos render a marker + a one-click "pin" action
    gctx = {"mid": 555, "repo": "myorg/payments-api", "source": "auto",
            "raw": {"deploys": [], "release": None, "runs": [], "commits": []}}
    sub = app._github_submenu(gctx)
    assert "auto-detected" in sub.title, sub.title
    assert any("pin this repo" in (getattr(c, "title", "") or "")
               for c in sub.children if c), [c.title for c in sub.children if c]
    app._make_repo_confirmer(555, "myorg/payments-api")(None)
    assert app.state["repos"]["555"] == "myorg/payments-api"
    assert "555" not in app.state.get("repos_auto", {})

print("SMOKE TEST PASSED ✅")
