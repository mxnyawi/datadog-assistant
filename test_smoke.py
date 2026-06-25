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
rumps.notifications = lambda fn: fn  # decorator that registers a click handler
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
banner_urls = []  # records the url= passed to each banner (clickable-banner wiring)
da.notify_banner = lambda t, s, m, sound=None, url=None: (
    notifications.append(("banner", t, m)), banner_urls.append(url))
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
    # alert banners carry the monitor url so a bundled-app click can open it
    assert any(u for u in banner_urls), banner_urls

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

    # ---- Datadog-native service context: parsers ----
    assert da.service_from_monitor(
        {"tags": ["env:prod", "service:payments"]}) == "payments"
    assert da.service_from_monitor(
        {"query": "avg(last_5m):avg:lat{service:checkout,env:prod} > 1"}) == \
        "checkout"
    assert da.service_from_monitor({"tags": [], "query": ""}) is None
    assert da.version_from_monitor({"tags": ["version:1.2.3"]}) == "1.2.3"
    assert da.normalize_repo_url("github.com/o/r") == "https://github.com/o/r"
    assert da.normalize_repo_url("git@github.com:o/r.git") == "https://github.com/o/r"
    assert da.repo_urls_from_tags(
        ["git.repository_url:github.com/o/r", "env:prod"]) == \
        ["https://github.com/o/r"]
    assert da.classify_link("Runbook", "https://wiki.acme/x") == "runbook"
    assert da.classify_link("", "https://github.com/o/r") == "repo"
    assert da.classify_link(
        "Board", "https://app.datadoghq.com/dashboard/abc") == "dashboard"
    mlinks = da.extract_message_links(
        "Check [Runbook](https://wiki.acme/run) and https://github.com/o/r @pd")
    kinds = {l["kind"] for l in mlinks}
    assert "runbook" in kinds and "repo" in kinds, mlinks
    assert all(l["url"].startswith("http") for l in mlinks)  # no @-handles

    svc_def = da.parse_service_definition({"attributes": {"schema": {
        "dd-service": "payments", "team": "core-pay",
        "links": [
            {"name": "Source", "type": "repo",
             "url": "https://github.com/o/payments"},
            {"name": "Runbook", "type": "runbook", "url": "https://wiki/r"},
            {"name": "Board", "type": "dashboard", "url": "https://dd/dash/1"}],
        "integrations": {"pagerduty": {"service-url": "https://pd/svc"}},
        "codeLocations": [
            {"repositoryURL": "https://github.com/o/payments-lib"}]}}})
    assert svc_def["name"] == "payments" and svc_def["team"] == "core-pay"
    assert len(svc_def["links"]["repo"]) == 2          # link + codeLocation
    assert svc_def["links"]["runbook"][0]["url"] == "https://wiki/r"
    assert svc_def["oncall"][0]["label"] == "pagerduty"
    assert da.is_deploy_event({"title": "Deployed payments v2"}, ["deploy"])
    assert not da.is_deploy_event({"title": "cpu high"}, ["deploy"])

    # ---- _service_links: catalog + tags + message, deduped ----
    app.services = {"payments": svc_def}
    smon = {"id": 901, "name": "checkout latency", "overall_state": "Alert",
            "options": {}, "tags": ["service:payments", "version:9.9"],
            "message": "Repo: https://github.com/o/payments"}
    info = app._service_links(smon)
    assert info["service"] == "payments" and info["team"] == "core-pay"
    assert info["version"] == "9.9"
    repo_urls = [r["url"] for r in info["links"]["repo"]]
    assert repo_urls.count("https://github.com/o/payments") == 1, repo_urls  # deduped
    assert "https://github.com/o/payments-lib" in repo_urls                  # codeLocation
    assert info["links"]["dashboard"][0]["url"] == "https://dd/dash/1"       # catalog
    assert info["oncall"][0]["url"] == "https://pd/svc"

    # ---- deploy events + correlation ----
    smon["state"] = {"groups": {"h": {"status": "Alert",
                                      "last_triggered_ts": NOW - 1380}}}
    astart = time.time() - app._alert_duration(smon)
    app.client.get_events = lambda tags, start, end, sources=None: [
        {"id": 55, "title": "Deployed payments abc123",
         "date_happened": astart - 600, "tags": ["service:payments"]},
        {"id": 56, "title": "unrelated note", "date_happened": NOW - 50}]
    dmap = app._fetch_deploys([smon])
    dctx = dmap[901]
    assert "Deploy" in dctx["headline"] and "before this alert" in dctx["headline"]
    assert len(dctx["events"]) == 1, dctx          # only the deploy kept
    assert dctx["suspect_url"].endswith("id=55"), dctx

    # ---- render: 🧭 panel + inline suspect headline ----
    app.deploys = dmap
    app.monitors = [smon]
    app._rebuild_menu()
    mi = next(i for i in app.menu
              if i and getattr(i, "title", "").startswith("🔴 checkout"))
    labels = [c.title for c in mi.children if c]
    assert any("Deploy" in t and "before this alert" in t for t in labels), labels
    panel = next(c for c in mi.children
                 if c and getattr(c, "title", "").startswith("🧭 payments"))
    pl = [c.title for c in panel.children if c]
    assert any("Repo:" in t for t in pl), pl
    assert any("version 9.9" in t for t in pl), pl
    assert any("Recent deploys" in t for t in pl), pl
    assert any("Runbook:" in t for t in pl), pl
    assert any("On-call: pagerduty" in t for t in pl), pl
    assert any("Software Catalog" in t for t in pl), pl

    # ---- deploy hint rides along on the alert notification ----
    app.deploys = {902: {"headline": "🚀 Deploy “x” 4m before this alert",
                         "sig": "x"}}
    app.cfg["service_context"]["notify_correlation"] = True
    app.snooze_until = 0
    notifications.clear()
    app.prev_states[902] = "OK"
    app._handle_new_monitors([{"id": 902, "name": "svc", "overall_state": "Alert",
                               "options": {}}])
    assert any("Deploy" in m for k, t, m in notifications), notifications

    # ---- muted monitor still firing must alert when unmuted (issue #13) ----
    app.deploys = {}
    app.snooze_until = 0
    notifications.clear()
    muted_fire = {"id": 950, "name": "pay-api", "overall_state": "Alert",
                  "options": {"silenced": {"*": None}}}
    app._handle_new_monitors([muted_fire])         # firing but muted -> silent
    assert not notifications, ("muted alert should not notify", notifications)
    unmuted = {"id": 950, "name": "pay-api", "overall_state": "Alert",
               "options": {}}
    app._handle_new_monitors([unmuted])            # unmuted, still firing
    assert any("ALERT" in t for k, t, m in notifications), \
        ("unmute should surface the still-active alert", notifications)
    # and it shouldn't re-fire on the next poll while it stays unmuted+firing
    notifications.clear()
    app._handle_new_monitors([unmuted])
    assert not notifications, ("no duplicate alert while steadily firing",
                               notifications)

    # ---- service resolution fallback ladder (non-uniform monitors) ----
    rs = da.resolve_service
    assert rs({"tags": ["service:pay"]}) == ("pay", "tag")
    assert rs({"tags": ["kube_app_name:web"]}) == ("web", "tag:kube_app_name")
    assert rs({"tags": ["kube_deployment:api"]})[0] == "api"
    assert rs({"tags": ["app:billing"]}) == ("billing", "tag:app")
    assert rs({"tags": ["application:ledger"]})[0] == "ledger"
    assert rs({"tags": ["dd-service:cart"]})[0] == "cart"
    assert rs({"tags": [],
               "query": "avg(last_5m):avg:lat{service:checkout} > 1"}) == \
        ("checkout", "query")
    assert rs({"tags": [], "name": "[web-store] high latency"}) == \
        ("web-store", "name")
    assert rs({"tags": [], "name": "[P1] disk full"})[0] is None   # priority, not svc
    assert rs({"type": "composite", "query": "1234 && 5678", "tags": []})[0] is None
    assert rs({"tags": []})[0] is None

    # ---- team / git / repo extraction ----
    assert da.team_from_monitor({"tags": ["team:core"]}) == "core"
    assert da.team_from_monitor({"tags": ["owner:sre"]}) == "sre"
    assert da.team_from_monitor(
        {"tags": [], "message": "ping @team-payments now"}) == "payments"
    gm = da.git_meta_from_monitor(
        {"tags": ["git.commit.sha:abcdef0123456", "git.branch:main"]})
    assert gm["sha"] == "abcdef0123456" and gm["branch"] == "main"
    assert da.commit_url("https://github.com/o/r", "abc123") == \
        "https://github.com/o/r/commit/abc123"
    assert da.commit_url("https://bitbucket.org/o/r", "abc123").endswith(
        "/commits/abc123")
    assert da.repo_urls_from_tags(["git.repository_url:github.com/o/r"]) == \
        ["https://github.com/o/r"]

    # ---- catalog parser handles every schema version ----
    v2_schema = {
        "schema-version": "v2", "dd-service": "legacy", "team": "core",
        "repos": [{"name": "Source", "url": "https://github.com/o/legacy"}],
        "docs": [{"name": "Design", "url": "https://wiki/legacy"}]}
    v2 = da.parse_service_definition({"attributes": {"schema": v2_schema}})
    assert v2["links"]["repo"][0]["url"] == "https://github.com/o/legacy"
    assert v2["links"]["doc"][0]["url"] == "https://wiki/legacy"
    v3_schema = {
        "apiVersion": "v3", "kind": "service",
        "metadata": {"name": "checkout", "owner": "checkout-team",
                     "links": [{"name": "Runbook", "type": "runbook",
                                "url": "https://wiki/run"}]},
        "datadog": {"codeLocations": [
            {"repositoryURL": "https://github.com/o/checkout"}]},
        "integrations": {"opsgenie": {"serviceURL": "https://og/x"}}}
    v3 = da.parse_service_definition({"attributes": {"schema": v3_schema}})
    assert v3["name"] == "checkout" and v3["team"] == "checkout-team"
    assert v3["links"]["repo"][0]["url"] == "https://github.com/o/checkout"
    assert v3["links"]["runbook"][0]["url"] == "https://wiki/run"
    assert v3["oncall"][0]["label"] == "opsgenie"

    # ---- deploy detection by CI/CD source (no keyword needed) ----
    assert da.is_deploy_event({"source_type_name": "github", "title": "x"}, [])
    assert da.is_deploy_event({"source_type_name": "jenkins"}, [])
    assert not da.is_deploy_event(
        {"source_type_name": "nagios", "title": "cpu high"}, ["deploy"])

    # ---- _service_links: team fallback + commit link + resolution method ----
    app.services = {}
    app.deploys = {}
    fmon = {"id": 71, "name": "[billing] errors", "overall_state": "Alert",
            "options": {}, "tags": ["app:billing", "owner:fin-team",
                                    "git.repository_url:github.com/o/billing",
                                    "git.commit.sha:deadbeef999", "version:4.5"]}
    fi = app._service_links(fmon)
    assert fi["service"] == "billing" and fi["service_how"] == "tag:app"
    assert fi["team"] == "fin-team"                       # from owner: tag
    assert fi["links"]["repo"][0]["url"] == "https://github.com/o/billing"
    assert fi["commit"] == "https://github.com/o/billing/commit/deadbeef999"

    fitem = da.rumps.MenuItem("x")
    app._add_service_section(fitem, fmon, 71)
    panel = next(c for c in fitem.children
                 if c and getattr(c, "title", "").startswith("🧭 billing"))
    pl = [c.title for c in panel.children if c]
    assert any("matched via tag:app" in t for t in pl), pl
    assert any("version 4.5" in t and "deadbee" in t for t in pl), pl

    # ---- unresolved monitor explains itself instead of a silent blank ----
    bitem = da.rumps.MenuItem("y")
    app._add_service_section(bitem, {"id": 72, "name": "orphan", "tags": [],
                                     "overall_state": "Alert", "options": {}}, 72)
    assert any("No service/repo found" in (getattr(c, "title", "") or "")
               for c in bitem.children if c), \
        [c.title for c in bitem.children if c]

# ---- clickable-notification helpers --------------------------------------
# A notification click should open the monitor url it was tagged with.
opened = []
_real_open_url = da.open_url
da.open_url = lambda u: opened.append(u)
try:
    da._notification_handler({"url": "https://app.datadoghq.com/monitors/42"})
    assert opened == ["https://app.datadoghq.com/monitors/42"], opened
    # malformed / empty payloads must not raise or open anything
    opened.clear()
    da._notification_handler(None)
    da._notification_handler({})
    da._notification_handler("not-a-dict")
    assert opened == [], opened
finally:
    da.open_url = _real_open_url

# Off a bundle (bare script / Linux CI) there's no bundle id, so notify_banner
# falls back to the osascript path instead of the clickable rumps one.
assert da._bundle_id() is None, da._bundle_id()

print("SMOKE TEST PASSED ✅")
