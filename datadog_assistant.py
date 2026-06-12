#!/usr/bin/env python3
"""
🐶 Datadog Assistant — a personal Datadog menu bar app for macOS.

Lives in your menu bar, polls your Datadog monitors, and makes alerts
IMPOSSIBLE to ignore (native banners, unmissable modal popups, sounds).

Features
--------
- 🚨 Menu bar icon changes + shows a count when monitors alert
- 🔔 Native macOS notifications on alert/warn/no-data/recovery
- 🛑 Optional "modal alert" mode — a popup you must dismiss (for when
  banners, emails and Teams messages get ignored)
- 🔴🟡🟢 Monitors grouped by state, each with: open-in-Datadog,
  mute (1h/4h/24h/forever), unmute, and delete
- ➕ Create new metric monitors straight from the menu bar
- 🔗 Quick links to Dashboards / Monitors / Logs / APM / Incidents
  plus your own custom links from the config
- 😴 Snooze, 🏷 tag filtering, ⏱ refresh interval, 🌐 any Datadog site
- 🔐 Keys from config file, environment, or the macOS Keychain

Config lives at ~/.config/datadog-assistant/config.json
"""

import base64
import gzip
import http.client
import json
import os
import re
import subprocess
import sys
import threading
import time
import queue
import webbrowser
import urllib.request
import urllib.parse
import urllib.error
from datetime import datetime

try:
    import rumps
except ImportError:
    sys.exit(
        "rumps is not installed. Run:  pip3 install rumps\n"
        "(or use the provided install.sh)"
    )

APP_NAME = "Datadog Assistant"
CONFIG_DIR = os.path.expanduser("~/.config/datadog-assistant")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

DEFAULT_CONFIG = {
    "api_key": "",                 # or set DD_API_KEY env var, or use keychain
    "app_key": "",                 # or set DD_APP_KEY env var, or use keychain
    "use_keychain": False,         # read keys from macOS Keychain (see README)
    "site": "datadoghq.com",       # datadoghq.eu, us3.datadoghq.com, us5..., ap1...
    "app_subdomain": "app",        # orgs with a custom subdomain: "yourorg" (else links re-ask login)
    "browser": "",                 # open links in a specific browser, e.g. "Google Chrome"
                                   # — "" uses the system default (often Safari, where
                                   # you may not have a Datadog session)
    "refresh_seconds": 60,
    "tag_filter": "",              # e.g. "team:payments env:prod" — only show matching monitors
    "name_filter": "",             # substring match on monitor names
    "notifications": {
        "enabled": True,
        "style": "both",           # "banner" | "modal" | "both"  (modal = unmissable popup)
        "sound": True,
        "sound_name": "Sosumi",    # any of /System/Library/Sounds (Sosumi, Glass, Hero, Submarine...)
        "notify_on_warn": True,
        "notify_on_no_data": True,
        "notify_on_recovery": True,
        "renotify_minutes": 30     # re-alert if a monitor is STILL alerting after N min (0 = off)
    },
    "icons": {
        "ok": "🐶",
        "alert": "🚨",
        "warn": "⚠️",
        "no_data": "🤷",
        "snoozed": "😴",
        "error": "🔌",
        "show_count": True
    },
    "menu": {
        "show_ok_monitors": True,
        "max_per_group": 25,
        "group_order": ["Alert", "Warn", "No Data", "OK", "Muted"]
    },
    "severity": {
        # Per-priority notification rules (monitor priority P1..P5, detected
        # from the monitor's priority field, a priority:pN tag, or "[P1]" in
        # the name). Fields omitted here fall back to "notifications".
        "rules": {
            "p1": {"style": "both", "renotify_minutes": 10, "icon": "‼️"},
            "p2": {"style": "both", "renotify_minutes": 30, "icon": "🚨"},
            "p3": {"style": "banner", "renotify_minutes": 60},
            "default": {}
        }
    },
    "context": {
        "show_triggered_groups": True,   # which hosts/groups are firing
        "max_groups_shown": 3,
        "show_sparkline": True,          # 📈 live metric trend on alerts
        "sparkline_window_minutes": 60,
        "show_incidents": True,          # 🔥 active Datadog incidents
        "auto_dashboard_links": True,    # 📊 your dashboards in Quick Links
        "max_dashboards": 8
    },
    "no_data_triage": {
        # Split No Data into "likely broken" (top-level, notifies) and
        # "quiet" (collapsed 🤫 submenu, silent) using monitor settings,
        # monitor type, staleness, and a live metric-history probe.
        "enabled": True,
        "stale_hours": 48,           # silent longer than this = quiet (retired/seasonal)
        "probe_lookback_hours": 24,  # metric history window for flowing-then-stopped check
        "max_probes": 6              # metric-history queries per refresh
    },
    "digest_hour": None,                 # e.g. 9 = morning summary at 9am
    "jira": {
        "enabled": False,
        "base_url": "",                  # https://yourcompany.atlassian.net
        "email": "",                     # your Atlassian account email
        "api_token": "",                 # or Keychain: datadog-assistant-jira-token
        "project_key": "OPS",
        "issue_type": "Task",
        "labels": ["datadog-alert"],
        "auto_create": False,            # auto-ticket on new alerts
        "auto_create_max_p": 2,          # only P1/P2 alerts auto-create
        "dedupe": True                   # skip if an open ticket exists
    },
    "quick_links": [
        {"name": "📊 Dashboards", "path": "/dashboard/lists"},
        {"name": "📟 Monitors", "path": "/monitors/manage"},
        {"name": "🪵 Logs", "path": "/logs"},
        {"name": "🧵 APM Traces", "path": "/apm/traces"},
        {"name": "🔥 Incidents", "path": "/incidents"},
        {"name": "🏠 Infrastructure", "path": "/infrastructure"}
    ],
    "custom_links": [
        # {"name": "💳 Payments Dashboard", "url": "https://app.datadoghq.com/dashboard/abc-123"}
    ]
}

STATE_EMOJI = {
    "Alert": "🔴",
    "Warn": "🟡",
    "OK": "🟢",
    "No Data": "⚪",
    "Quiet": "🤫",
    "Muted": "🔇",
    "Unknown": "❓",
    "Skipped": "⏭",
    "Ignored": "🙈",
}

GROUP_HEADERS = {
    "Alert": "🔴 ALERTING",
    "Warn": "🟡 WARNING",
    "No Data": "⚪ NO DATA (likely broken)",
    "Quiet": "🤫 QUIET (no data, expected)",
    "OK": "🟢 OK",
    "Muted": "🔇 MUTED",
}

# Monitor types watching event streams: zero matching events is usually the
# healthy state, so No Data on these rarely means anything is broken.
EVENT_MONITOR_TYPES = {
    "log alert", "event alert", "event-v2 alert", "rum alert",
    "trace-analytics alert", "error-tracking alert",
    "ci-pipelines alert", "ci-tests alert", "audit alert",
}


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def deep_merge(base, override):
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if not os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "w") as f:
            json.dump(DEFAULT_CONFIG, f, indent=2)
    try:
        with open(CONFIG_PATH) as f:
            user_cfg = json.load(f)
    except (json.JSONDecodeError, OSError):
        user_cfg = {}
    return deep_merge(DEFAULT_CONFIG, user_cfg)


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


OPEN_BROWSER = ""  # set from cfg at startup; "" = system default browser


def open_url(url):
    """Open url in the configured browser (cfg "browser", e.g. "Google
    Chrome") so links land where your Datadog session lives, instead of
    the system-default browser asking you to log in every time."""
    if OPEN_BROWSER and sys.platform == "darwin":
        try:
            subprocess.run(["open", "-a", OPEN_BROWSER, url],
                           check=False, timeout=10)
            return
        except Exception:
            pass  # unknown app name etc. — fall back to default
    webbrowser.open(url)


def keychain_set(service, value):
    try:
        out = subprocess.run(
            ["security", "add-generic-password", "-U", "-s", service,
             "-a", os.environ.get("USER", "datadog-assistant"), "-w", value],
            capture_output=True, timeout=5)
        return out.returncode == 0
    except Exception:
        return False


def keychain_get(service):
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=5
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


STATE_PATH = os.path.join(CONFIG_DIR, "state.json")


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(STATE_PATH, "w") as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass


# --------------------------------------------------------------------------
# Severity & context helpers
# --------------------------------------------------------------------------

def parse_priority(m):
    """Monitor priority 1..5 from the priority field, tags, or '[P1]' name."""
    p = m.get("priority")
    if isinstance(p, int) and 1 <= p <= 5:
        return p
    for t in m.get("tags") or []:
        mt = re.match(r"priority:p?([1-5])$", str(t).lower())
        if mt:
            return int(mt.group(1))
    mt = re.search(r"\[P([1-5])\]", m.get("name", ""), re.IGNORECASE)
    return int(mt.group(1)) if mt else None


SPARK_BLOCKS = "▁▂▃▄▅▆▇█"


def sparkline(values, width=14):
    vals = [v for v in values if v is not None]
    if not vals:
        return ""
    if len(vals) > width:
        step = len(vals) / width
        vals = [vals[int(i * step)] for i in range(width)]
    lo, hi = min(vals), max(vals)
    if hi == lo:
        return SPARK_BLOCKS[3] * len(vals)
    return "".join(SPARK_BLOCKS[int((v - lo) / (hi - lo) * 7)] for v in vals)


def fmt_duration(secs):
    secs = int(secs)
    if secs < 3600:
        return f"{max(1, secs // 60)}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60:02d}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600}h"


def fmt_num(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return str(v)
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    return f"{v:.4g}"


def extract_metric_query(monitor_query):
    """'avg(last_5m):avg:system.cpu.user{env:prod} by {host} > 90'
       -> 'avg:system.cpu.user{env:prod} by {host}'  ('' if not parseable)"""
    mt = re.match(
        r"^[a-z0-9_]+\(last_[^)]*\):(.*?)\s*(?:[<>]=?|==|!=)\s*[-\d.]+\s*$",
        (monitor_query or "").strip())
    return mt.group(1).strip() if mt else ""


def unique_title(label, seen):
    """rumps menus are dicts keyed by title — identical titles collide and
    one item silently disappears. Pad with zero-width spaces to keep every
    label visually identical but unique as a key."""
    while label in seen:
        label += "​"
    seen.add(label)
    return label


def acquire_single_instance_lock():
    """flock-based guard so a manual run + the LaunchAgent can't produce two
    menu bar icons. The lock dies with the process, so no stale-PID issues."""
    import fcntl
    os.makedirs(CONFIG_DIR, exist_ok=True)
    lock = open(os.path.join(CONFIG_DIR, "app.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("Datadog Assistant is already running 🐶")
    return lock  # caller must keep the reference alive


# --------------------------------------------------------------------------
# Datadog API client (stdlib only — no extra deps)
# --------------------------------------------------------------------------

class DatadogClient:
    def __init__(self, cfg):
        self.cfg = cfg

    @property
    def site(self):
        return self.cfg.get("site", "datadoghq.com")

    @property
    def api_base(self):
        return f"https://api.{self.site}/api/v1"

    @property
    def app_base(self):
        sub = self.cfg.get("app_subdomain") or "app"
        return f"https://{sub}.{self.site}"

    def _keys(self):
        api = self.cfg.get("api_key") or os.environ.get("DD_API_KEY", "")
        app = self.cfg.get("app_key") or os.environ.get("DD_APP_KEY", "")
        if self.cfg.get("use_keychain"):
            api = keychain_get("datadog-assistant-api-key") or api
            app = keychain_get("datadog-assistant-app-key") or app
        return api, app

    def has_keys(self):
        api, app = self._keys()
        return bool(api and app)

    def _request(self, method, path, params=None, body=None, version="v1"):
        api, app = self._keys()
        url = f"https://api.{self.site}/api/{version}" + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        last_err = None
        for attempt in range(3):
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("DD-API-KEY", api)
            req.add_header("DD-APPLICATION-KEY", app)
            req.add_header("Content-Type", "application/json")
            req.add_header("Accept-Encoding", "gzip")
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    if resp.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                    payload = raw.decode()
                    return json.loads(payload) if payload else {}
            except (http.client.IncompleteRead, ConnectionResetError,
                    TimeoutError) as e:
                last_err = e
                time.sleep(1 + attempt)
        raise last_err

    def get_monitors(self):
        # Paginate so one giant response can't stall mid-read on large orgs.
        params = {"group_states": "all", "page_size": 200}
        tag_filter = self.cfg.get("tag_filter", "").strip()
        if tag_filter:
            params["monitor_tags"] = ",".join(tag_filter.split())
        name_filter = self.cfg.get("name_filter", "").strip()
        if name_filter:
            params["name"] = name_filter
        monitors, page = [], 0
        while True:
            batch = self._request("GET", "/monitor",
                                  params={**params, "page": page})
            monitors.extend(batch)
            if len(batch) < params["page_size"]:
                return monitors
            page += 1

    def mute_monitor(self, monitor_id, hours=None):
        params = {}
        if hours:
            params["end"] = int(time.time()) + int(hours * 3600)
        return self._request("POST", f"/monitor/{monitor_id}/mute", params=params)

    def unmute_monitor(self, monitor_id):
        return self._request("POST", f"/monitor/{monitor_id}/unmute")

    def delete_monitor(self, monitor_id):
        return self._request("DELETE", f"/monitor/{monitor_id}")

    def create_monitor(self, name, query, message):
        body = {
            "name": name,
            "type": "metric alert",
            "query": query,
            "message": message,
            "tags": ["created_by:datadog-assistant"],
            "options": {"notify_no_data": False, "thresholds": {}},
        }
        return self._request("POST", "/monitor", body=body)

    def monitor_url(self, monitor_id):
        return f"{self.app_base}/monitors/{monitor_id}"

    def incident_url(self, public_id):
        return f"{self.app_base}/incidents/{public_id}"

    def get_incidents(self):
        """Active (non-resolved) incidents, newest first."""
        data = self._request("GET", "/incidents",
                             params={"page[size]": 25}, version="v2")
        out = []
        for inc in data.get("data", []):
            a = inc.get("attributes", {})
            if (a.get("state") or "").lower() == "resolved":
                continue
            fields = a.get("fields") or {}
            sev = (fields.get("severity") or {}).get("value") or "UNKNOWN"
            out.append({
                "public_id": a.get("public_id"),
                "title": a.get("title", "incident"),
                "severity": sev,
                "state": (a.get("state") or "").lower(),
                "created": a.get("created"),
            })
        return out

    def list_dashboards(self):
        data = self._request("GET", "/dashboard")
        return [{"title": d.get("title", "dashboard"),
                 "url": self.app_base + d.get("url", "")}
                for d in data.get("dashboards", [])]

    def query_metrics(self, query, window_minutes=60):
        now = int(time.time())
        return self._request("GET", "/query", params={
            "from": now - window_minutes * 60, "to": now, "query": query})


def http_error_detail(e):
    """Jira (and most JSON APIs) put the actual problem in the error body,
    e.g. {"errors": {"issuetype": "The issue type selected is invalid."}} —
    'HTTP 400: Bad Request' alone is undebuggable from a notification."""
    try:
        body = json.loads(e.read().decode())
        msgs = list(body.get("errorMessages") or [])
        msgs += [f"{k}: {v}" for k, v in (body.get("errors") or {}).items()]
        if msgs:
            return "; ".join(msgs)
    except Exception:
        pass
    return getattr(e, "reason", None) or "request failed"


# --------------------------------------------------------------------------
# Jira client (Cloud REST v3, API-token auth)
#
# Works even when your Jira uses Okta SSO: Atlassian API tokens
# (id.atlassian.com → Security → API tokens) authenticate directly against
# Atlassian and bypass the SSO browser flow. A full Okta OAuth flow is only
# needed for self-hosted Jira Data Center — not implemented here.
# --------------------------------------------------------------------------

class JiraClient:
    def __init__(self, cfg):
        self.cfg = cfg or {}

    def enabled(self):
        return bool(self.cfg.get("enabled"))

    def _token(self):
        return (self.cfg.get("api_token")
                or keychain_get("datadog-assistant-jira-token"))

    def configured(self):
        return bool(self.cfg.get("base_url") and self.cfg.get("email")
                    and self._token())

    def _request(self, method, path, params=None, body=None):
        url = self.cfg["base_url"].rstrip("/") + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        raw = f"{self.cfg.get('email', '')}:{self._token()}".encode()
        req.add_header("Authorization", "Basic " + base64.b64encode(raw).decode())
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                payload = resp.read().decode()
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Jira {e.code}: {http_error_detail(e)}") from e

    def browse_url(self, key):
        return self.cfg["base_url"].rstrip("/") + "/browse/" + key

    def find_open_issue(self, monitor_id):
        jql = f'labels = "dd-monitor-{monitor_id}" AND statusCategory != Done'
        # /rest/api/3/search was removed by Atlassian (returns 410 Gone);
        # its replacement is /search/jql with the same shape for our use
        data = self._request("GET", "/rest/api/3/search/jql",
                             params={"jql": jql, "maxResults": 1, "fields": "key"})
        issues = data.get("issues", [])
        return issues[0]["key"] if issues else None

    def create_issue(self, monitor_id, name, dd_url, context=""):
        text = f"Datadog monitor alert: {name}\n\n{dd_url}"
        if context:
            text += f"\n\nContext at creation: {context}"
        body = {"fields": {
            "project": {"key": self.cfg.get("project_key", "OPS")},
            "issuetype": {"name": self.cfg.get("issue_type", "Task")},
            "summary": f"[Datadog] 🔴 {name}"[:254],
            "labels": list(self.cfg.get("labels", [])) + [f"dd-monitor-{monitor_id}"],
            "description": {"type": "doc", "version": 1, "content": [
                {"type": "paragraph",
                 "content": [{"type": "text", "text": text}]}]},
        }}
        return self._request("POST", "/rest/api/3/issue", body=body).get("key")


# --------------------------------------------------------------------------
# macOS notifications
# --------------------------------------------------------------------------

def _osa(script):
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=30)
    except Exception:
        pass


def play_sound(name):
    path = f"/System/Library/Sounds/{name}.aiff"
    if os.path.exists(path):
        try:
            subprocess.Popen(["afplay", path])
        except Exception:
            pass


def notify_banner(title, subtitle, message, sound_name=None):
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        f'display notification "{esc(message)}" '
        f'with title "{esc(title)}" subtitle "{esc(subtitle)}"'
    )
    if sound_name:
        script += f' sound name "{sound_name}"'
    _osa(script)


def notify_modal(title, message, url=None):
    """The unmissable one. Blocks until dismissed; can jump to Datadog."""
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    def run():
        buttons = '{"Open in Datadog 🔗", "Dismiss"}' if url else '{"Dismiss"}'
        default = '"Open in Datadog 🔗"' if url else '"Dismiss"'
        script = (
            f'display alert "{esc(title)}" message "{esc(message)}" '
            f'as critical buttons {buttons} default button {default} '
            f'giving up after 300'
        )
        try:
            out = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True, text=True, timeout=320
            )
            if url and "Open in Datadog" in (out.stdout or ""):
                open_url(url)
        except Exception:
            pass

    threading.Thread(target=run, daemon=True).start()


# --------------------------------------------------------------------------
# The menu bar app
# --------------------------------------------------------------------------

class DatadogAssistant(rumps.App):
    def __init__(self):
        self.cfg = load_config()
        global OPEN_BROWSER
        OPEN_BROWSER = self.cfg.get("browser", "")
        self.client = DatadogClient(self.cfg)
        self.jira = JiraClient(self.cfg.get("jira", {}))
        icons = self.cfg["icons"]
        super().__init__(APP_NAME, title=icons["ok"], quit_button=None)

        self.monitors = []
        self.incidents = []
        self.dashboards = []
        self.enrich = {}             # monitor id -> {spark, now, crit}
        self.nodata_probe = {}       # monitor id -> "stopped" | "silent"
        self.state = load_state()    # persists jira tickets + digest date
        self._dash_ts = 0
        self.prev_states = {}        # id -> overall_state
        self.last_notified = {}      # id -> unix ts (for renotify)
        self.snooze_until = 0
        self.last_refresh = None
        self.last_error = None
        self.results = queue.Queue()
        self._fetching = False

        self._menu_fp = None
        self._refresh_item = None
        self._activity = self._prevent_app_nap()

        self.menu = self._build_static_menu()
        self._rebuild_menu()

        interval = max(15, int(self.cfg.get("refresh_seconds", 60)))
        self.poll_timer = rumps.Timer(self._poll_tick, interval)
        self.poll_timer.start()
        self.drain_timer = rumps.Timer(self._drain_results, 2)
        self.drain_timer.start()
        self._poll_tick(None)  # immediate first fetch

    def _prevent_app_nap(self):
        """App Nap throttles NSTimer for 'idle' background apps — fatal for
        an alerting tool. Hold the activity token for the process lifetime
        (App Nap resumes the moment the token is released)."""
        try:
            from Foundation import NSProcessInfo
            # NSActivityUserInitiatedAllowingIdleSystemSleep:
            # no timer throttling, but the Mac may still sleep normally.
            options = 0x00FFFFFF & ~(1 << 20)
            return NSProcessInfo.processInfo().beginActivityWithOptions_reason_(
                options, "Polling Datadog for alerts")
        except Exception:
            return None  # non-macOS / no pyobjc — nothing to do

    # -------------------- polling --------------------

    def _poll_tick(self, _):
        if self._fetching:
            return
        self._fetching = True
        threading.Thread(target=self._fetch, daemon=True).start()

    def _fetch(self):
        try:
            if not self.client.has_keys():
                self.results.put(("error", "No API/APP keys configured"))
            else:
                payload = {"monitors": self.client.get_monitors()}
                ctx = self.cfg.get("context", {})
                if ctx.get("show_incidents", True):
                    try:
                        payload["incidents"] = self.client.get_incidents()
                    except Exception:
                        pass  # e.g. key lacks incidents scope — hide section
                if ctx.get("auto_dashboard_links", True) and \
                        time.time() - self._dash_ts > 3600:
                    try:
                        payload["dashboards"] = self.client.list_dashboards()
                        self._dash_ts = time.time()
                    except Exception:
                        pass
                if ctx.get("show_sparkline", True):
                    payload["enrich"] = self._fetch_enrichment(payload["monitors"])
                payload["nodata_probe"] = self._probe_no_data(payload["monitors"])
                self.results.put(("data", payload))
        except urllib.error.HTTPError as e:
            self.results.put(("error", f"HTTP {e.code} from Datadog API"))
        except Exception as e:
            self.results.put(("error", str(e)[:120]))
        finally:
            self._fetching = False

    def _drain_results(self, _):
        updated = False
        while True:
            try:
                kind, payload = self.results.get_nowait()
            except queue.Empty:
                break
            if kind == "data":
                self.last_error = None
                self.last_refresh = datetime.now()
                if "incidents" in payload:
                    self.incidents = payload["incidents"]
                if "dashboards" in payload:
                    self.dashboards = payload["dashboards"]
                self.enrich = payload.get("enrich") or {}
                # keep probe verdicts for monitors still in No Data, fold in
                # the new ones (only a capped batch is probed per refresh)
                nodata_ids = {m.get("id") for m in payload["monitors"]
                              if m.get("overall_state") == "No Data"}
                self.nodata_probe = {
                    **{k: v for k, v in self.nodata_probe.items()
                       if k in nodata_ids},
                    **payload.get("nodata_probe", {})}
                self._handle_new_monitors(payload["monitors"])
                self._maybe_digest()
            else:
                self.last_error = payload
            updated = True
        if updated:
            # Rebuilding leaks Cocoa objects over time (rumps #64), so only
            # rebuild when menu-relevant content actually changed; otherwise
            # just refresh the timestamp row in place.
            fp = self._menu_fingerprint()
            if fp != self._menu_fp:
                self._rebuild_menu()
            elif self._refresh_item is not None and self.last_refresh:
                self._refresh_item.title = (
                    f"🔄 Refresh now (last: "
                    f"{self.last_refresh.strftime('%H:%M:%S')})")
            self._update_title()

    def _menu_fingerprint(self):
        mons = tuple(sorted(
            (m.get("id"), m.get("name"), m.get("overall_state"),
             parse_priority(m) or 0,
             bool(m.get("options", {}).get("silenced")),
             len(self._triggered_groups(m)),
             self._triage_no_data(m)[0]
             if m.get("overall_state") == "No Data" else "")
            for m in self.monitors))
        enr = tuple(sorted(
            (k, v.get("spark"), v.get("now")) for k, v in self.enrich.items()))
        inc = tuple((i.get("public_id"), i.get("title"), i.get("severity"))
                    for i in self.incidents)
        dash = tuple(d["title"] for d in self.dashboards)
        # while anything is firing, refresh at most every 5 min anyway so
        # the "triggered Xm ago" rows don't go stale
        hot = any(m.get("overall_state") in ("Alert", "Warn", "No Data")
                  for m in self.monitors)
        bucket = int(time.time() // 300) if hot else 0
        return (self.last_error, time.time() < self.snooze_until,
                mons, enr, inc, dash, bucket)

    def _fetch_enrichment(self, monitors):
        """Live metric values + sparklines for the hottest alerting monitors."""
        window = int(self.cfg["context"].get("sparkline_window_minutes", 60))
        out = {}
        hot = [m for m in monitors
               if m.get("overall_state") in ("Alert", "Warn")
               and m.get("type") in ("metric alert", "query alert")]
        hot.sort(key=lambda m: parse_priority(m) or 9)
        for m in hot[:8]:
            q = extract_metric_query(m.get("query", ""))
            if not q:
                continue
            try:
                series = self.client.query_metrics(q, window).get("series", [])
                if not series:
                    continue
                points = [p[1] for p in series[0].get("pointlist", [])]
                lasts = []
                for s in series:
                    pl = s.get("pointlist") or []
                    if pl and pl[-1][1] is not None:
                        lasts.append(pl[-1][1])
                thr = (m.get("options", {}).get("thresholds") or {}).get("critical")
                out[m["id"]] = {"spark": sparkline(points),
                                "now": max(lasts) if lasts else None,
                                "crit": thr}
            except Exception:
                continue
        return out

    def _probe_no_data(self, monitors):
        """For No Data metric monitors: query the metric's recent history.
        Data in the window then nothing now → 'stopped' (agent/host likely
        died). No datapoints in the whole window → 'silent' (was never
        flowing — retired host, seasonal job). Runs in the fetch thread;
        capped per refresh, already-probed monitors are skipped."""
        tcfg = self.cfg.get("no_data_triage", {})
        if not tcfg.get("enabled", True):
            return {}
        lookback = int(tcfg.get("probe_lookback_hours", 24)) * 60
        budget = int(tcfg.get("max_probes", 6))
        out = {}
        for m in monitors:
            if budget <= 0:
                break
            if (m.get("overall_state") != "No Data"
                    or m.get("type") not in ("metric alert", "query alert")
                    or m.get("id") in self.nodata_probe):
                continue
            q = extract_metric_query(m.get("query", ""))
            if not q:
                continue
            budget -= 1
            try:
                series = self.client.query_metrics(q, lookback).get("series", [])
                has_data = any(p[1] is not None
                               for s in series
                               for p in (s.get("pointlist") or []))
                out[m["id"]] = "stopped" if has_data else "silent"
            except Exception:
                continue
        return out

    # -------------------- No Data triage --------------------

    def _nodata_age(self, m):
        groups = (m.get("state") or {}).get("groups") or {}
        ts = [g.get("last_nodata_ts") for g in groups.values()
              if g.get("status") == "No Data" and g.get("last_nodata_ts")]
        if ts:
            return max(0, time.time() - min(ts))
        mod = m.get("overall_state_modified")
        if mod:
            try:
                dt = datetime.fromisoformat(str(mod).replace("Z", "+00:00"))
                return max(0, time.time() - dt.timestamp())
            except ValueError:
                pass
        return None

    def _triage_no_data(self, m):
        """('broken' | 'quiet', reason) — is this No Data an outage or just
        an expected silence? Defaults to 'broken' when signals are ambiguous:
        a dead service looks exactly like No Data."""
        if not self.cfg.get("no_data_triage", {}).get("enabled", True):
            return "broken", ""
        opts = m.get("options") or {}
        omd = str(opts.get("on_missing_data") or "")
        if omd in ("resolve", "show_ok"):
            return "quiet", "monitor resolves on missing data"
        wants_nodata = bool(opts.get("notify_no_data")) \
            or omd.startswith("show_and_notify")
        if not wants_nodata:
            return "quiet", "no-data notifications are off on this monitor"
        if (m.get("type") or "") in EVENT_MONITOR_TYPES:
            return "quiet", "event-stream monitor — silence is usually normal"
        age = self._nodata_age(m)
        stale = int(self.cfg["no_data_triage"].get("stale_hours", 48)) * 3600
        if age and age > stale:
            return "quiet", f"silent for {fmt_duration(age)} — likely retired"
        probe = self.nodata_probe.get(m.get("id"))
        if probe == "stopped":
            return "broken", "metric was flowing, then stopped"
        if probe == "silent":
            window = self.cfg["no_data_triage"].get("probe_lookback_hours", 24)
            return "quiet", f"no datapoints in the last {window}h"
        return "broken", "monitor wants no-data alerts"

    # -------------------- severity & context --------------------

    def _severity_rule(self, m):
        rules = self.cfg.get("severity", {}).get("rules", {})
        rule = dict(rules.get("default", {}))
        p = parse_priority(m)
        if p:
            rule.update(rules.get(f"p{p}", {}))
        return rule

    def _alert_duration(self, m):
        groups = (m.get("state") or {}).get("groups") or {}
        ts = [g.get("last_triggered_ts") for g in groups.values()
              if g.get("status") in ("Alert", "Warn", "No Data")
              and g.get("last_triggered_ts")]
        return max(0, time.time() - min(ts)) if ts else None

    def _triggered_groups(self, m):
        groups = (m.get("state") or {}).get("groups") or {}
        return [name for name, g in groups.items()
                if g.get("status") in ("Alert", "Warn", "No Data")
                and name != "*"]

    def _context_line(self, m):
        """'P1 · ⏱ 23m · 📟 3 groups · 📈 97.2 (crit 90)' — the severity TLDR."""
        parts = []
        p = parse_priority(m)
        if p:
            parts.append(f"P{p}")
        dur = self._alert_duration(m)
        if dur:
            parts.append(f"⏱ {fmt_duration(dur)}")
        grps = self._triggered_groups(m)
        if grps:
            parts.append(f"📟 {len(grps)} group{'s' if len(grps) != 1 else ''}")
        e = self.enrich.get(m.get("id"))
        if e and e.get("now") is not None:
            s = f"📈 {fmt_num(e['now'])}"
            if e.get("crit") is not None:
                s += f" (crit {fmt_num(e['crit'])})"
            parts.append(s)
        return " · ".join(parts)

    # -------------------- state transitions & notifications --------------------

    def _handle_new_monitors(self, monitors):
        self.monitors = monitors
        ncfg = self.cfg["notifications"]
        now = time.time()
        snoozed = now < self.snooze_until

        for m in monitors:
            mid = m.get("id")
            state = m.get("overall_state", "Unknown")
            prev = self.prev_states.get(mid)
            name = m.get("name", f"monitor {mid}")
            url = self.client.monitor_url(mid)
            muted = bool(m.get("options", {}).get("silenced"))

            should, title, body = None, None, None
            if prev is None:
                # first sighting (app launch): baseline, don't spam.
                # Pre-existing alerts start their renotify clock now.
                if state == "Alert":
                    self.last_notified.setdefault(mid, now)
            elif state != prev:
                if state == "Alert":
                    should = True
                    title, body = "🔴 ALERT — Datadog", name
                elif state == "Warn" and ncfg.get("notify_on_warn", True):
                    should = True
                    title, body = "🟡 Warning — Datadog", name
                elif state == "No Data" and ncfg.get("notify_on_no_data", True):
                    verdict, reason = self._triage_no_data(m)
                    if verdict == "broken":
                        should = True
                        title = "⚪ No Data — Datadog"
                        body = f"{name} ({reason})" if reason else name
                elif state == "OK" and prev in ("Alert", "Warn", "No Data") \
                        and ncfg.get("notify_on_recovery", True):
                    should = True
                    title, body = "🟢 Recovered — Datadog", name
            else:
                rule = self._severity_rule(m)
                renotify = rule.get("renotify_minutes",
                                    ncfg.get("renotify_minutes", 0))
                if state == "Alert" and renotify:
                    last = self.last_notified.get(mid, 0)
                    if now - last > renotify * 60:
                        should = True
                        title, body = "🔴 STILL ALERTING — Datadog", name

            self.prev_states[mid] = state

            if should and ncfg.get("enabled", True) and not snoozed and not muted:
                self.last_notified[mid] = now
                rule = self._severity_rule(m)
                style = rule.get("style", ncfg.get("style", "both"))
                sound = (rule.get("sound_name", ncfg.get("sound_name"))
                         if ncfg.get("sound", True) else None)
                ctx = self._context_line(m)
                if style in ("banner", "both"):
                    banner_body = f"{body} — {ctx}" if ctx else body
                    notify_banner(title, "Datadog Assistant 🐶", banner_body, sound)
                if style in ("modal", "both") and state == "Alert":
                    modal_body = body + (f"\n{ctx}" if ctx else "")
                    grps = self._triggered_groups(m)
                    if grps:
                        modal_body += "\n" + ", ".join(grps[:5])
                    notify_modal(title, modal_body, url)
                if sound and style == "modal":
                    play_sound(sound)

            # auto-create a Jira ticket on a fresh transition into Alert
            if state == "Alert" and prev is not None and prev != "Alert" \
                    and not muted:
                self._maybe_auto_jira(m)

    # -------------------- jira --------------------

    def _maybe_auto_jira(self, m):
        jcfg = self.cfg.get("jira", {})
        if not (jcfg.get("enabled") and jcfg.get("auto_create")):
            return
        if (parse_priority(m) or 9) > int(jcfg.get("auto_create_max_p", 2)):
            return
        self._create_jira(m, auto=True)

    def _create_jira(self, m, auto=False):
        mid, name = m.get("id"), m.get("name", "")
        url = self.client.monitor_url(mid)
        ctx = self._context_line(m)

        def run():
            try:
                if not self.jira.configured():
                    notify_banner("🎫 Jira not configured", "Datadog Assistant 🐶",
                                  "Fill in the jira section of config.json")
                    return
                if self.cfg["jira"].get("dedupe", True):
                    key = self.jira.find_open_issue(mid)
                    if key:
                        if not auto:
                            notify_banner("🎫 Ticket already open",
                                          "Datadog Assistant 🐶",
                                          f"{key} covers this monitor")
                        return
                key = self.jira.create_issue(mid, name, url, ctx)
                self.state.setdefault("jira_created", {})[str(mid)] = key
                save_state(self.state)
                notify_banner("🎫 Jira ticket created" + (" (auto)" if auto else ""),
                              "Datadog Assistant 🐶", f"{key} — {name[:60]}")
            except Exception as e:
                # modal, not banner: banners truncate and their "Show"
                # action goes nowhere, so the error was unreadable
                notify_modal("❌ Jira ticket failed", str(e)[:400])

        threading.Thread(target=run, daemon=True).start()

    def _make_jira_creator(self, m):
        def cb(_):
            self._create_jira(m)
        return cb

    # -------------------- daily digest --------------------

    def _maybe_digest(self):
        hour = self.cfg.get("digest_hour")
        if hour is None:
            return
        today = datetime.now().strftime("%Y-%m-%d")
        if self.state.get("digest_date") == today or datetime.now().hour < int(hour):
            return
        g = self._grouped()
        notify_banner("🌅 Datadog daily digest", "Datadog Assistant 🐶",
                      f"{len(g['Alert'])} alerting · {len(g['Warn'])} warn · "
                      f"{len(g['OK'])} ok · {len(self.incidents)} incidents 🔥")
        self.state["digest_date"] = today
        save_state(self.state)

    # -------------------- title (menu bar icon) --------------------

    def _grouped(self):
        groups = {"Alert": [], "Warn": [], "No Data": [], "Quiet": [],
                  "OK": [], "Muted": []}
        for m in self.monitors:
            muted = bool(m.get("options", {}).get("silenced"))
            state = m.get("overall_state", "Unknown")
            if muted:
                groups["Muted"].append(m)
            elif state == "No Data":
                verdict, _ = self._triage_no_data(m)
                groups["Quiet" if verdict == "quiet" else "No Data"].append(m)
            elif state in groups:
                groups[state].append(m)
            else:
                groups["OK"].append(m)
        return groups

    def _update_title(self):
        icons = self.cfg["icons"]
        if self.last_error and not self.monitors:
            # only show the plug when we have no data at all — a transient
            # network blip must not hide a known alerting state
            self.title = icons["error"]
            return
        if time.time() < self.snooze_until:
            self.title = icons["snoozed"]
            return
        g = self._grouped()
        if g["Alert"]:
            best = min((parse_priority(m) or 9) for m in g["Alert"])
            rules = self.cfg.get("severity", {}).get("rules", {})
            icon = rules.get(f"p{best}", {}).get("icon", icons["alert"])
            n = f" {len(g['Alert'])}" if icons.get("show_count", True) else ""
            self.title = f"{icon}{n}"
        elif g["Warn"]:
            n = f" {len(g['Warn'])}" if icons.get("show_count", True) else ""
            self.title = f"{icons['warn']}{n}"
        elif g["No Data"]:
            self.title = icons["no_data"]
        else:
            self.title = icons["ok"]

    # -------------------- menu construction --------------------

    def _build_static_menu(self):
        return []  # fully dynamic; rebuilt in _rebuild_menu

    def _rebuild_menu(self):
        self.menu.clear()
        self._menu_fp = self._menu_fingerprint()
        seen = set()  # rumps keys menus by title — keep them unique
        items = []

        # ---- status header ----
        g = self._grouped()
        if self.last_error:
            items.append(rumps.MenuItem(f"🔌 Error: {self.last_error}"))
        if self.monitors or not self.last_error:
            summary = (
                f"📊 {len(g['Alert'])} alerting · {len(g['Warn'])} warn · "
                f"{len(g['OK'])} ok · {len(g['Muted'])} muted"
            )
            if g["No Data"] or g["Quiet"]:
                summary += (f" · {len(g['No Data'])} no-data"
                            f" ({len(g['Quiet'])} quiet)")
            hdr = rumps.MenuItem(summary, callback=self._open_manage_monitors)
            items.append(hdr)

        ts = self.last_refresh.strftime("%H:%M:%S") if self.last_refresh else "never"
        self._refresh_item = rumps.MenuItem(f"🔄 Refresh now (last: {ts})",
                                            callback=self._manual_refresh, key="r")
        items.append(self._refresh_item)
        if time.time() < self.snooze_until:
            until = datetime.fromtimestamp(self.snooze_until).strftime("%H:%M")
            items.append(rumps.MenuItem(f"😴 Snoozed until {until} — wake up",
                                        callback=self._unsnooze))
        items.append(None)  # separator

        # ---- active incidents ----
        if self.incidents and self.cfg["context"].get("show_incidents", True):
            items.append(rumps.MenuItem(f"🔥 INCIDENTS ({len(self.incidents)})"))
            for inc in self.incidents[:10]:
                label = f"🔥 {inc['severity']} · {inc['title']}"
                if len(label) > 60:
                    label = label[:57] + "…"
                items.append(rumps.MenuItem(
                    unique_title(label, seen),
                    callback=self._make_opener(
                        self.client.incident_url(inc.get("public_id")))))
            items.append(None)

        # ---- monitor groups ----
        show_ok = self.cfg["menu"].get("show_ok_monitors", True)
        max_per = int(self.cfg["menu"].get("max_per_group", 25))
        order = list(self.cfg["menu"].get("group_order",
                                          ["Alert", "Warn", "No Data", "OK", "Muted"]))
        if "Quiet" not in order:  # configs predating no-data triage
            order.insert(order.index("No Data") + 1 if "No Data" in order
                         else len(order), "Quiet")
        for group in order:
            monitors = g.get(group, [])
            if not monitors:
                continue
            if group == "OK" and not show_ok:
                continue
            header = rumps.MenuItem(f"{GROUP_HEADERS[group]} ({len(monitors)})")
            if group in ("Alert", "Warn", "No Data"):
                # top-level, always visible
                items.append(header)
                for m in monitors[:max_per]:
                    items.append(self._monitor_item(m, group, seen))
            else:
                # collapsed into a submenu (its own title namespace)
                sub_seen = set()
                for m in monitors[:max_per]:
                    header.add(self._monitor_item(m, group, sub_seen))
                if len(monitors) > max_per:
                    header.add(rumps.MenuItem(f"… {len(monitors) - max_per} more"))
                items.append(header)
            items.append(None)

        # ---- actions ----
        items.append(rumps.MenuItem("➕ Add Monitor…", callback=self._add_monitor, key="n"))

        links = rumps.MenuItem("🔗 Quick Links")
        link_seen = set()
        for link in self.cfg.get("quick_links", []):
            links.add(rumps.MenuItem(
                unique_title(link["name"], link_seen),
                callback=self._make_opener(self.client.app_base + link["path"])))
        custom = self.cfg.get("custom_links", [])
        if custom:
            links.add(None)
            for link in custom:
                links.add(rumps.MenuItem(unique_title(link["name"], link_seen),
                                         callback=self._make_opener(link["url"])))
        if self.dashboards and self.cfg["context"].get("auto_dashboard_links", True):
            links.add(None)
            links.add(rumps.MenuItem("📊 MY DASHBOARDS"))
            for d in self.dashboards[:int(self.cfg["context"].get("max_dashboards", 8))]:
                t = d["title"] if len(d["title"]) <= 45 else d["title"][:42] + "…"
                links.add(rumps.MenuItem(unique_title(f"📊 {t}", link_seen),
                                         callback=self._make_opener(d["url"])))
        items.append(links)
        items.append(None)

        # ---- preferences ----
        items.append(self._prefs_menu())
        items.append(rumps.MenuItem("🩺 Test Notification", callback=self._test_notification))
        items.append(None)
        items.append(rumps.MenuItem("❌ Quit", callback=rumps.quit_application, key="q"))

        self.menu = items

    def _monitor_item(self, m, group, seen=None):
        mid = m.get("id")
        name = m.get("name", f"monitor {mid}")
        emoji = STATE_EMOJI.get(group if group in ("Muted", "Quiet") else
                                m.get("overall_state", "Unknown"), "❓")
        label = f"{emoji} {name}"
        if len(label) > 60:
            label = label[:57] + "…"
        if seen is not None:
            label = unique_title(label, seen)
        item = rumps.MenuItem(label)
        url = self.client.monitor_url(mid)

        # severity context — why should you care, at a glance
        if group in ("Alert", "Warn", "No Data", "Quiet"):
            ctx_cfg = self.cfg["context"]
            if group in ("No Data", "Quiet"):
                _, reason = self._triage_no_data(m)
                if reason:
                    item.add(rumps.MenuItem(f"🔍 {reason}"))
            p = parse_priority(m)
            if p:
                sev_name = {1: "critical", 2: "high", 3: "moderate",
                            4: "low", 5: "info"}.get(p, "")
                item.add(rumps.MenuItem(f"🎯 Priority P{p} — {sev_name}"))
            dur = self._alert_duration(m)
            if dur:
                item.add(rumps.MenuItem(f"⏱ Triggered {fmt_duration(dur)} ago"))
            e = self.enrich.get(mid)
            if e and e.get("spark"):
                val = f"  now {fmt_num(e['now'])}" if e.get("now") is not None else ""
                crit = f" (crit {fmt_num(e['crit'])})" if e.get("crit") is not None else ""
                item.add(rumps.MenuItem(f"📈 {e['spark']}{val}{crit}"))
            grps = self._triggered_groups(m)
            if grps and ctx_cfg.get("show_triggered_groups", True):
                maxg = int(ctx_cfg.get("max_groups_shown", 3))
                item.add(rumps.MenuItem(f"📟 Triggered on {len(grps)} group(s):"))
                for gname in grps[:maxg]:
                    item.add(rumps.MenuItem(f"      {gname}"))
                if len(grps) > maxg:
                    item.add(rumps.MenuItem(f"      … +{len(grps) - maxg} more"))
            item.add(None)

        item.add(rumps.MenuItem("🔗 Open in Datadog", callback=self._make_opener(url)))
        if self.jira.enabled():
            key = self.state.get("jira_created", {}).get(str(mid))
            if key:
                item.add(rumps.MenuItem(f"🎫 Open {key}",
                                        callback=self._make_opener(
                                            self.jira.browse_url(key))))
            item.add(rumps.MenuItem("🎫 Create Jira ticket",
                                    callback=self._make_jira_creator(m)))
        item.add(None)
        item.add(rumps.MenuItem("🔇 Mute 1 hour", callback=self._make_muter(mid, 1)))
        item.add(rumps.MenuItem("🔇 Mute 4 hours", callback=self._make_muter(mid, 4)))
        item.add(rumps.MenuItem("🔇 Mute 24 hours", callback=self._make_muter(mid, 24)))
        item.add(rumps.MenuItem("🔇 Mute forever", callback=self._make_muter(mid, None)))
        item.add(rumps.MenuItem("🔊 Unmute", callback=self._make_unmuter(mid)))
        item.add(None)
        item.add(rumps.MenuItem("🗑 Delete monitor…", callback=self._make_deleter(mid, name)))
        return item

    def _prefs_menu(self):
        prefs = rumps.MenuItem("⚙️ Preferences")

        # refresh interval
        interval = rumps.MenuItem("⏱ Refresh interval")
        current = int(self.cfg.get("refresh_seconds", 60))
        for label, secs in [("30 seconds", 30), ("1 minute", 60),
                            ("2 minutes", 120), ("5 minutes", 300),
                            ("15 minutes", 900)]:
            it = rumps.MenuItem(label, callback=self._make_interval_setter(secs))
            it.state = 1 if secs == current else 0
            interval.add(it)
        prefs.add(interval)

        # notification style
        style = rumps.MenuItem("🔔 Notification style")
        cur_style = self.cfg["notifications"].get("style", "both")
        for label, value in [("🪧 Banner only", "banner"),
                             ("🛑 Modal popup only (unmissable)", "modal"),
                             ("🪧+🛑 Both", "both")]:
            it = rumps.MenuItem(label, callback=self._make_style_setter(value))
            it.state = 1 if value == cur_style else 0
            style.add(it)
        prefs.add(style)

        # toggles
        ncfg = self.cfg["notifications"]
        notif = rumps.MenuItem("🔔 Notifications enabled",
                               callback=self._toggle_notifications)
        notif.state = 1 if ncfg.get("enabled", True) else 0
        prefs.add(notif)
        sound = rumps.MenuItem("🔊 Sound", callback=self._toggle_sound)
        sound.state = 1 if ncfg.get("sound", True) else 0
        prefs.add(sound)
        recov = rumps.MenuItem("🟢 Notify on recovery", callback=self._toggle_recovery)
        recov.state = 1 if ncfg.get("notify_on_recovery", True) else 0
        prefs.add(recov)
        okmon = rumps.MenuItem("👀 Show OK monitors in menu",
                               callback=self._toggle_show_ok)
        okmon.state = 1 if self.cfg["menu"].get("show_ok_monitors", True) else 0
        prefs.add(okmon)
        inc = rumps.MenuItem("🔥 Show incidents", callback=self._toggle_incidents)
        inc.state = 1 if self.cfg["context"].get("show_incidents", True) else 0
        prefs.add(inc)
        spark = rumps.MenuItem("📈 Sparklines on alerts",
                               callback=self._toggle_sparkline)
        spark.state = 1 if self.cfg["context"].get("show_sparkline", True) else 0
        prefs.add(spark)
        dash = rumps.MenuItem("📊 Auto dashboard links",
                              callback=self._toggle_dashboards)
        dash.state = 1 if self.cfg["context"].get("auto_dashboard_links", True) else 0
        prefs.add(dash)
        jira = rumps.MenuItem("🎫 Jira integration", callback=self._toggle_jira)
        jira.state = 1 if self.cfg["jira"].get("enabled", False) else 0
        prefs.add(jira)
        prefs.add(rumps.MenuItem("🎫 Edit Jira settings…",
                                 callback=self._edit_jira))
        prefs.add(None)

        # snooze
        snooze = rumps.MenuItem("😴 Snooze alerts")
        for label, mins in [("30 minutes", 30), ("1 hour", 60),
                            ("4 hours", 240), ("Rest of today", -1)]:
            snooze.add(rumps.MenuItem(label, callback=self._make_snoozer(mins)))
        prefs.add(snooze)

        # filters
        prefs.add(rumps.MenuItem("🏷 Set tag filter…", callback=self._set_tag_filter))
        prefs.add(None)

        # site
        site = rumps.MenuItem("🌐 Datadog site")
        for s in ["datadoghq.com", "datadoghq.eu", "us3.datadoghq.com",
                  "us5.datadoghq.com", "ap1.datadoghq.com", "ddog-gov.com"]:
            it = rumps.MenuItem(s, callback=self._make_site_setter(s))
            it.state = 1 if s == self.cfg.get("site") else 0
            site.add(it)
        prefs.add(site)

        prefs.add(rumps.MenuItem("📝 Open config file", callback=self._open_config))
        return prefs

    # -------------------- callbacks --------------------

    def _make_opener(self, url):
        def cb(_):
            open_url(url)
        return cb

    def _open_manage_monitors(self, _):
        open_url(self.client.app_base + "/monitors/manage")

    def _manual_refresh(self, _):
        self._poll_tick(None)

    def _api_action(self, fn, ok_msg):
        def run():
            try:
                fn()
                notify_banner("✅ Done", "Datadog Assistant 🐶", ok_msg)
            except Exception as e:
                notify_banner("❌ Failed", "Datadog Assistant 🐶", str(e)[:100])
            self._poll_tick(None)
        threading.Thread(target=run, daemon=True).start()

    def _make_muter(self, mid, hours):
        def cb(_):
            label = f"for {hours}h" if hours else "indefinitely"
            self._api_action(lambda: self.client.mute_monitor(mid, hours),
                             f"Monitor muted {label} 🔇")
        return cb

    def _make_unmuter(self, mid):
        def cb(_):
            self._api_action(lambda: self.client.unmute_monitor(mid),
                             "Monitor unmuted 🔊")
        return cb

    def _make_deleter(self, mid, name):
        def cb(_):
            win = rumps.Window(
                title="🗑 Delete monitor?",
                message=f'This permanently deletes:\n\n"{name}"\n\n'
                        f'Type DELETE to confirm.',
                default_text="", ok="Delete", cancel="Cancel", dimensions=(220, 24))
            resp = win.run()
            if resp.clicked and resp.text.strip() == "DELETE":
                self._api_action(lambda: self.client.delete_monitor(mid),
                                 f"Deleted “{name[:40]}” 🗑")
        return cb

    def _add_monitor(self, _):
        w1 = rumps.Window(title="➕ New monitor — name",
                          message="A clear, human-readable monitor name:",
                          default_text="High CPU on prod",
                          ok="Next", cancel="Cancel", dimensions=(320, 24))
        r1 = w1.run()
        if not r1.clicked or not r1.text.strip():
            return
        w2 = rumps.Window(
            title="➕ New monitor — query",
            message="Datadog monitor query, e.g.\n"
                    "avg(last_5m):avg:system.cpu.user{env:prod} by {host} > 90",
            default_text="avg(last_5m):avg:system.cpu.user{*} > 90",
            ok="Next", cancel="Cancel", dimensions=(420, 48))
        r2 = w2.run()
        if not r2.clicked or not r2.text.strip():
            return
        w3 = rumps.Window(
            title="➕ New monitor — message",
            message="Notification message (supports @-handles):",
            default_text="🚨 {{name}} triggered — check it out! @your-team",
            ok="Create ✅", cancel="Cancel", dimensions=(420, 48))
        r3 = w3.run()
        if not r3.clicked:
            return
        name, query, msg = r1.text.strip(), r2.text.strip(), r3.text.strip()
        self._api_action(lambda: self.client.create_monitor(name, query, msg),
                         f"Created “{name}” ➕")

    def _make_interval_setter(self, secs):
        def cb(_):
            self.cfg["refresh_seconds"] = secs
            save_config(self.cfg)
            self.poll_timer.stop()
            self.poll_timer = rumps.Timer(self._poll_tick, max(15, secs))
            self.poll_timer.start()
            self._rebuild_menu()
        return cb

    def _make_style_setter(self, value):
        def cb(_):
            self.cfg["notifications"]["style"] = value
            save_config(self.cfg)
            self._rebuild_menu()
        return cb

    def _toggle(self, section, key, default=True):
        cur = self.cfg[section].get(key, default)
        self.cfg[section][key] = not cur
        save_config(self.cfg)
        self._rebuild_menu()

    def _toggle_notifications(self, _):
        self._toggle("notifications", "enabled")

    def _toggle_sound(self, _):
        self._toggle("notifications", "sound")

    def _toggle_recovery(self, _):
        self._toggle("notifications", "notify_on_recovery")

    def _toggle_show_ok(self, _):
        self._toggle("menu", "show_ok_monitors")

    def _toggle_incidents(self, _):
        self._toggle("context", "show_incidents")

    def _toggle_sparkline(self, _):
        self._toggle("context", "show_sparkline")

    def _toggle_dashboards(self, _):
        self._toggle("context", "auto_dashboard_links")

    def _toggle_jira(self, _):
        enabling = not self.cfg["jira"].get("enabled", False)
        if enabling and not self.jira.configured():
            if not self._jira_setup():
                return  # wizard cancelled — stay disabled
        self._toggle("jira", "enabled", default=False)
        self.jira = JiraClient(self.cfg.get("jira", {}))
        if self.cfg["jira"].get("enabled"):
            notify_banner("🎫 Jira enabled", "Datadog Assistant 🐶",
                          "Create tickets from any alert's submenu")

    def _jira_setup(self):
        """First-enable wizard — without it the Jira toggle silently flips a
        config flag that can't do anything until base_url/email/token exist."""
        steps = [
            ("base_url", "Jira base URL",
             "e.g. https://yourcompany.atlassian.net", False),
            ("email", "Atlassian account email",
             "The email you log into Jira with", False),
            ("api_token", "Jira API token",
             "Create one at id.atlassian.com → Security → API tokens.\n"
             "Stored in the macOS Keychain. Leave blank to keep the\n"
             "current token.", True),
            ("project_key", "Jira project key",
             "Tickets are created in this project, e.g. OPS", False),
            ("issue_type", "Issue type",
             "Must exist in your project: Task, Bug, Story…\n"
             "(team-managed projects often don't have \"Task\")", False),
            ("labels", "Ticket labels",
             "Space- or comma-separated Jira labels added to every\n"
             "ticket, e.g.: team-payments datadog-alert\n"
             "Point your board's filter at your team's label.", False),
        ]
        for key, title, message, secret in steps:
            if key == "labels":
                prefill = " ".join(self.cfg["jira"].get("labels") or [])
            elif secret:
                prefill = ""
            else:
                prefill = self.cfg["jira"].get(key) or ""
            win = rumps.Window(
                title=f"🎫 Jira setup — {title}", message=message,
                default_text=prefill,
                ok="Next", cancel="Cancel", dimensions=(320, 24), secure=secret)
            resp = win.run()
            if not resp.clicked:
                return False
            value = resp.text.strip()
            if key == "api_token":
                if not value:
                    continue  # keep whatever token is already stored
                if keychain_set("datadog-assistant-jira-token", value):
                    self.cfg["jira"]["api_token"] = ""  # keychain wins
                else:
                    self.cfg["jira"][key] = value
            elif key == "labels":
                # Jira labels can't contain spaces, so both separators are safe
                self.cfg["jira"]["labels"] = [
                    t for t in re.split(r"[,\s]+", value) if t]
            else:
                self.cfg["jira"][key] = value
        save_config(self.cfg)
        return True

    def _edit_jira(self, _):
        if self._jira_setup():
            self.jira = JiraClient(self.cfg.get("jira", {}))
            notify_banner("🎫 Jira settings saved", "Datadog Assistant 🐶",
                          f"Tickets go to project "
                          f"{self.cfg['jira'].get('project_key', '?')}")

    def _make_snoozer(self, mins):
        def cb(_):
            if mins == -1:
                end = datetime.now().replace(hour=23, minute=59, second=59)
                self.snooze_until = end.timestamp()
            else:
                self.snooze_until = time.time() + mins * 60
            self._rebuild_menu()
            self._update_title()
        return cb

    def _unsnooze(self, _):
        self.snooze_until = 0
        self._rebuild_menu()
        self._update_title()

    def _set_tag_filter(self, _):
        win = rumps.Window(
            title="🏷 Tag filter",
            message="Space-separated tags — only monitors matching ALL tags "
                    "are shown.\nLeave empty for all monitors.\n"
                    "Example: team:payments env:prod",
            default_text=self.cfg.get("tag_filter", ""),
            ok="Save", cancel="Cancel", dimensions=(320, 24))
        resp = win.run()
        if resp.clicked:
            self.cfg["tag_filter"] = resp.text.strip()
            save_config(self.cfg)
            self._poll_tick(None)

    def _make_site_setter(self, s):
        def cb(_):
            self.cfg["site"] = s
            save_config(self.cfg)
            self._rebuild_menu()
            self._poll_tick(None)
        return cb

    def _open_config(self, _):
        subprocess.run(["open", "-t", CONFIG_PATH])

    def _test_notification(self, _):
        ncfg = self.cfg["notifications"]
        sound = ncfg.get("sound_name") if ncfg.get("sound", True) else None
        notify_banner("🔴 ALERT — Datadog", "Datadog Assistant 🐶",
                      "This is a test alert. Looking good! ✅", sound)
        if ncfg.get("style", "both") in ("modal", "both"):
            notify_modal("🔴 TEST ALERT — Datadog",
                         "This is what an unmissable alert looks like. 💪",
                         self.client.app_base + "/monitors/manage")


if __name__ == "__main__":
    _lock = acquire_single_instance_lock()
    DatadogAssistant().run()
