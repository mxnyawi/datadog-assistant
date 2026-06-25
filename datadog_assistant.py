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
import copy
import gzip
import hashlib
import http.client
import http.server
import json
import os
import re
import shutil
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
    "auth": "keys",                # "keys" | "oauth" | "lastpass"
    "api_key": "",                 # or set DD_API_KEY env var, or use keychain
    "app_key": "",                 # or set DD_APP_KEY env var, or use keychain
    "use_keychain": False,         # read keys from macOS Keychain (see README)
    "api_key_cmd": "",             # pull keys from a password manager instead,
    "app_key_cmd": "",             # e.g. "lpass show --password dd-api-key" or
                                   # "op read op://Engineering/Datadog/api-key"
    "lastpass": {                  # auth=lastpass: shared vault entry
        "entry": "",               # e.g. "Shared-SRE/datadog-assistant"
        "api_key_field": "datadogAPIKey",
        "app_key_field": "datadogAPPKey",
        "jira_client_id_field": "jiraClientID",
        "jira_client_secret_field": "jiraClientSecret",
        "jira_token_field": ""     # optional — API token (non-OAuth) fallback
    },
    "oauth_client_id": "",         # OAuth mode: Client ID of your Datadog OAuth client
    "oauth_domain": "",            # OAuth mode: org region (datadoghq.eu...) — set on connect
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
    "dlq": {
        # Pull dead-letter-queue monitors out of the state groups and into one
        # dedicated 💀 section, so the queues you babysit live in one place.
        # A monitor is "DLQ" if any pattern appears in its name (or local
        # rename), query, or tags — case-insensitive.
        "enabled": True,
        "patterns": ["dlq", "dead letter", "dead-letter",
                     "dead_letter", "deadletter"],
        "match_query": True,
        "match_tags": True,
        "exclusive": True            # also hide them from Alert/Warn/OK/… groups
    },
    "service_context": {
        # Surface the repo / deploy / runbook links Datadog ALREADY knows
        # about for a firing monitor — no extra credentials. Three sources,
        # all from the data we already hold or one cheap API each:
        #   • the monitor's own tags (service:, git.repository_url:, version:)
        #   • links embedded in the monitor message (Markdown + bare URLs)
        #   • the Software Catalog service definition (repo/runbook/docs/on-call)
        # plus recent deploy EVENTS for the service, flagged when one shipped
        # just before the alert started.
        "enabled": True,
        "use_catalog": True,         # pull links from the Software Catalog
        "use_message_links": True,   # scrape links out of the monitor message
        "show_deploys": True,        # recent deploy events for the service
        "deploy_event_sources": [],  # restrict to these event sources ([] = any)
        "deploy_keywords": ["deploy", "deployment", "rollout", "released",
                            "release", "shipped"],
        "correlate_minutes": 120,    # flag a deploy within N min before the alert
        "lookback_hours": 24,
        "max_services_per_poll": 6,  # cap deploy-event queries per refresh
        "cache_seconds": 180,
        "show_on": ["Alert", "Warn", "No Data"],
        "notify_correlation": True,  # add the "🚀 deployed Nm before" line to alerts
        "show_unresolved_hint": True # tell you when a monitor has no service/repo
    },
    "digest_hour": None,                 # e.g. 9 = morning summary at 9am
    "jira": {
        "enabled": False,
        "auth": "token",                 # "token" (API token) or "oauth" (Okta/SSO-friendly)
        "base_url": "",                  # https://yourcompany.atlassian.net
        "email": "",                     # your Atlassian account email
        "api_token": "",                 # or Keychain: datadog-assistant-jira-token
        "api_token_cmd": "",             # or a password-manager CLI (see api_key_cmd)
        "oauth_client_id": "",           # OAuth mode: from developer.atlassian.com
        "cloud_id": "",                  # OAuth mode: set automatically on connect
        "project_key": "OPS",
        "issue_type": "Task",
        "labels": ["datadog-alert"],
        "auto_label_from_tags": True,    # + datadog-alert-<monitor tag> per tag
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
    "DLQ": "💀 DEAD LETTER QUEUES",
}

# Severity ordering for sorting within the DLQ section (lower = more urgent).
SEV_RANK = {"Alert": 0, "Warn": 1, "No Data": 2, "Quiet": 3, "OK": 4, "Muted": 5}

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
    # Deep-copy so the merged result never aliases base's nested mutables.
    # Otherwise a later config edit (e.g. a Preferences toggle) would mutate
    # the module-level DEFAULT_CONFIG in place, corrupting the defaults.
    out = copy.deepcopy(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
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


_SECRET_CMD_CACHE = {}
_SECRET_CMD_CACHE_TIME = {}
_SECRET_CACHE_TTL = 900  # re-fetch from vault every 15 minutes


def _cache_get(key):
    if key in _SECRET_CMD_CACHE:
        if time.time() - _SECRET_CMD_CACHE_TIME.get(key, 0) < _SECRET_CACHE_TTL:
            return _SECRET_CMD_CACHE[key]
        del _SECRET_CMD_CACHE[key]
        _SECRET_CMD_CACHE_TIME.pop(key, None)
    return None


def _cache_set(key, val):
    _SECRET_CMD_CACHE[key] = val
    _SECRET_CMD_CACHE_TIME[key] = time.time()


def secret_from_cmd(cmd):
    """Pull a secret from a password-manager CLI (LastPass lpass,
    1Password op, Bitwarden bw, Vault...) — the command's stdout is the
    secret. Lets companies centralise rotation/revocation/audit instead of
    provisioning API keys onto every machine. Successful lookups are cached
    in memory (with TTL) so the vault isn't hit on every poll; failures
    (e.g. vault locked) are not cached and retry next poll."""
    if not cmd:
        return ""
    cached = _cache_get(cmd)
    if cached is not None:
        return cached
    try:
        out = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True,
                             text=True, timeout=30)
        val = out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        val = ""
    if val:
        _cache_set(cmd, val)
    return val


def _find_lpass():
    """Locate the lpass binary, checking common Homebrew paths that LaunchAgents miss."""
    for p in ("/opt/homebrew/bin/lpass", "/usr/local/bin/lpass"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("lpass") or "lpass"


_LPASS = _find_lpass()


def lpass_logged_in():
    """Check if the user is logged into LastPass CLI."""
    try:
        out = subprocess.run([_LPASS, "status"], capture_output=True,
                             text=True, timeout=10)
        return out.returncode == 0 and "Logged in" in out.stdout
    except Exception:
        return False


def lpass_get(entry, field):
    """Retrieve a field from a LastPass secure note (key=value format in Notes).
    Falls back to --field for custom-field entries."""
    if not entry or not field:
        return ""
    cache_key = f"lpass:{entry}:{field}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached
    # Try --field first (works for custom fields)
    val = ""
    try:
        out = subprocess.run(
            [_LPASS, "show", "--field", field, entry],
            capture_output=True, text=True, timeout=30)
        val = out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        pass
    # Fallback: parse key=value lines from --notes (secure notes)
    if not val:
        try:
            out = subprocess.run(
                [_LPASS, "show", "--notes", entry],
                capture_output=True, text=True, timeout=30)
            if out.returncode == 0:
                for line in out.stdout.splitlines():
                    if "=" in line:
                        k, _, v = line.partition("=")
                        if k.strip() == field:
                            val = v.strip()
                            break
        except Exception:
            pass
    if val:
        _cache_set(cache_key, val)
    return val


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


def fmt_ago(epoch):
    """'13m ago' / '2h 04m ago' / '3d 1h ago' from a unix timestamp."""
    if not epoch:
        return ""
    return f"{fmt_duration(max(0, time.time() - epoch))} ago"


# --------------------------------------------------------------------------
# Mining repo / deploy / runbook info out of Datadog's own data
# --------------------------------------------------------------------------

# Unified Service Tagging does NOT automatically tag monitors — a monitor
# only carries service:/team: if a human or IaC added them, or the query
# scopes by them. So we fall back through the tag keys Datadog auto-emits
# (kube_*) and the custom keys teams actually use, then the query, then the
# name. Order matters: most-canonical first.
SERVICE_TAG_KEYS = [
    "service", "kube_app_name", "kube_deployment", "kube_service",
    "app", "application", "servicename", "service_name", "service-name",
    "dd-service", "dd_service", "component", "kube_app_component",
]
TEAM_TAG_KEYS = ["team", "owner", "squad", "dd_team", "dd-team", "group"]
REPO_TAG_KEYS = ["git.repository_url", "git_repository_url", "repository_url",
                 "repository", "repo"]
# leading "[token]" in a name is a service only if it isn't a priority/env tag
_NAME_PREFIX_SKIP = {"p1", "p2", "p3", "p4", "p5", "prod", "production",
                     "staging", "stage", "dev", "qa", "test", "uat", "sandbox",
                     "critical", "warn", "warning", "info", "sev1", "sev2"}


def _tag_value(tags, key):
    pre = key + ":"
    for t in tags or []:
        s = str(t)
        if s.startswith(pre):
            return s[len(pre):]
    return None


def resolve_service(m):
    """(service, how) via the realistic fallback ladder. Composite monitors
    hold sub-monitor IDs in their query, so we don't parse a query for them."""
    tags = m.get("tags") or []
    for key in SERVICE_TAG_KEYS:
        v = _tag_value(tags, key)
        if v:
            return v, ("tag" if key == "service" else f"tag:{key}")
    if m.get("type") != "composite":
        mt = re.search(r"[{,\s]service:([a-zA-Z0-9._\-/]+)", m.get("query") or "")
        if mt:
            return mt.group(1), "query"
    mt = re.match(r"\s*[\[\(]([a-zA-Z0-9][a-zA-Z0-9._\-]{1,40})[\]\)]",
                  m.get("name") or "")
    if mt and mt.group(1).lower() not in _NAME_PREFIX_SKIP:
        return mt.group(1), "name"
    return None, None


def service_from_monitor(m):
    return resolve_service(m)[0]


def team_from_monitor(m):
    """Owning team: a team-ish tag, else an @team-<handle> in the message."""
    for key in TEAM_TAG_KEYS:
        v = _tag_value(m.get("tags"), key)
        if v:
            return v
    mt = re.search(r"@team-([a-zA-Z0-9._\-]+)", m.get("message") or "")
    return mt.group(1) if mt else None


def version_from_monitor(m):
    v = _tag_value(m.get("tags"), "version")
    if v:
        return v
    mt = re.search(r"version:([a-zA-Z0-9._\-]+)", m.get("query") or "")
    return mt.group(1) if mt else None


def git_meta_from_monitor(m):
    """commit sha + branch, if Source Code Integration tagged the monitor."""
    tags = m.get("tags") or []
    return {"sha": _tag_value(tags, "git.commit.sha"),
            "branch": _tag_value(tags, "git.branch")}


def normalize_repo_url(v):
    """A repo from a tag may be 'github.com/o/r' (Datadog's normalized form),
    'git@github.com:o/r.git', or a full URL — return a browser-openable URL."""
    v = (v or "").strip()
    if not v:
        return ""
    if v.startswith("git@"):
        v = v.replace(":", "/", 1).replace("git@", "https://", 1)
    if not v.startswith(("http://", "https://")):
        v = "https://" + v
    return v[:-4] if v.endswith(".git") else v


def repo_urls_from_tags(tags):
    """git.repository_url / repository / repo tags → repo URLs."""
    out = []
    for key in REPO_TAG_KEYS:
        v = _tag_value(tags, key)
        if v:
            url = normalize_repo_url(v)
            if url and url not in out:
                out.append(url)
    return out


def commit_url(repo_url, sha):
    """Best-effort link to a commit on the common forge layouts."""
    if not (repo_url and sha):
        return None
    host = urllib.parse.urlparse(repo_url).netloc
    if "bitbucket" in host:
        return f"{repo_url}/commits/{sha}"
    return f"{repo_url}/commit/{sha}"          # github / gitlab / azure-ish


_MD_LINK = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")
_BARE_URL = re.compile(r"https?://[^\s>)\]}\"']+")
_REPO_HOSTS = ("github.com", "gitlab.com", "bitbucket.org", "dev.azure.com")


def classify_link(label, url):
    lbl = (label or "").lower()
    u = (url or "").lower()
    host = urllib.parse.urlparse(u).netloc
    if any(h in host for h in _REPO_HOSTS) or host.startswith("git."):
        return "repo"
    if any(k in lbl for k in ("runbook", "playbook", "wiki", "confluence",
                              "notion", "on-call", "oncall", "sop")):
        return "runbook"
    if "/dashboard" in u or "dashboard" in lbl:
        return "dashboard"
    if any(k in lbl for k in ("doc", "documentation", "readme")):
        return "doc"
    return "other"


def extract_message_links(message):
    """Links teams embed in the monitor message — Markdown [label](url) first
    (the label helps us classify), then any remaining bare URLs."""
    if not message:
        return []
    out, seen = [], set()
    for mt in _MD_LINK.finditer(message):
        label, url = mt.group(1).strip(), mt.group(2).strip()
        if url in seen:
            continue
        seen.add(url)
        out.append({"label": label, "url": url, "kind": classify_link(label, url)})
    for mt in _BARE_URL.finditer(message):
        url = mt.group(0).rstrip(".,);")
        if url in seen:
            continue
        seen.add(url)
        out.append({"label": url, "url": url, "kind": classify_link("", url)})
    return out


_CATALOG_LINK_KIND = {
    "repo": "repo", "code": "repo", "source": "repo", "vcs": "repo",
    "git": "repo", "runbook": "runbook", "doc": "doc",
    "documentation": "doc", "docs": "doc", "dashboard": "dashboard",
}


def _add_link(links, kind, label, url):
    if url:
        links[kind].append({"label": label or kind, "url": url})


def parse_service_definition(item):
    """One Software Catalog entry → {name, team, links{...}, oncall}. Handles
    every schema Datadog has shipped: v2 (separate `repos[]`/`docs[]`), v2.1/
    v2.2 (unified `links[]`), and the v3 entity model (`metadata.links`,
    `metadata.owner`, `datadog.codeLocations`)."""
    schema = ((item or {}).get("attributes") or {}).get("schema") or item or {}
    is_v3 = str(schema.get("apiVersion") or "").startswith("v3") \
        or isinstance(schema.get("metadata"), dict)
    if is_v3:
        meta = schema.get("metadata") or {}
        name = meta.get("name") or schema.get("dd-service")
        team = meta.get("owner") or schema.get("team")
        raw_links = meta.get("links") or schema.get("links") or []
        code_locs = ((schema.get("datadog") or {}).get("codeLocations")
                     or schema.get("codeLocations") or [])
    else:
        name = schema.get("dd-service") or schema.get("name")
        team = schema.get("team") or schema.get("dd-team")
        raw_links = schema.get("links") or []
        code_locs = schema.get("codeLocations") or []
    if not name:
        return None
    links = {"repo": [], "runbook": [], "doc": [], "dashboard": [], "other": []}
    for ln in raw_links:
        kind = _CATALOG_LINK_KIND.get((ln.get("type") or "").lower(), "other")
        _add_link(links, kind, ln.get("name"), ln.get("url"))
    for r in schema.get("repos") or []:              # v2 separate array
        _add_link(links, "repo", (r.get("name") if isinstance(r, dict) else None),
                  r.get("url") if isinstance(r, dict) else r)
    for d in schema.get("docs") or []:               # v2 separate array
        _add_link(links, "doc", (d.get("name") if isinstance(d, dict) else None),
                  d.get("url") if isinstance(d, dict) else d)
    for cl in code_locs:                             # v2.2 / v3
        if isinstance(cl, dict):
            _add_link(links, "repo", "code", cl.get("repositoryURL"))
    oncall = []
    integrations = schema.get("integrations") or {}
    for key in ("pagerduty", "opsgenie"):
        v = integrations.get(key)
        if isinstance(v, dict):
            url = v.get("service-url") or v.get("serviceURL") or v.get("url")
        else:
            url = v if isinstance(v, str) else None
        if url:
            oncall.append({"label": key, "url": url})
    return {"name": name, "team": team, "links": links, "oncall": oncall}


# Event sources Datadog attributes to CI/CD systems — a deploy event from any
# of these counts even if its title doesn't say "deploy".
DEPLOY_EVENT_SOURCES = {
    "github", "github_apps", "gitlab", "bitbucket", "jenkins",
    "amazon_codedeploy", "octopus_deploy", "octopusdeploy", "argocd",
    "spinnaker", "harness", "circleci", "azure_devops", "deployment",
}


def is_deploy_event(e, keywords):
    """Treat an event as a deploy if it came from a known CI/CD source, or if
    its title/text/tags/alert_type mention a deploy keyword."""
    src = str(e.get("source_type_name") or e.get("source") or "").lower()
    if src in DEPLOY_EVENT_SOURCES:
        return True
    hay = " ".join([
        str(e.get("title") or ""), str(e.get("text") or ""),
        " ".join(str(t) for t in (e.get("tags") or [])),
        src, str(e.get("alert_type") or "")]).lower()
    return any(k.lower() in hay for k in keywords)


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
#
# Two auth modes:
#   "keys"  — API key + Application key in the DD-API-KEY / DD-APPLICATION-KEY
#             headers (the classic setup).
#   "oauth" — OAuth 2.0 authorization-code + PKCE: you log in once in the
#             browser, the app keeps a (rotating) refresh token in the Keychain
#             and calls the API with short-lived Bearer access tokens. The org's
#             region comes back from the consent redirect, so it's auto-detected.
# --------------------------------------------------------------------------

DD_OAUTH_PORT = 8918  # must match the OAuth client's registered callback URL
DD_OAUTH_SCOPES = ("monitors_read monitors_write monitors_downtime "
                   "dashboards_read incident_read metrics_read events_read")


class DatadogClient:
    def __init__(self, cfg):
        self.cfg = cfg
        self._access = {"token": "", "expires": 0}  # cached OAuth access token

    def auth_mode(self):
        return self.cfg.get("auth", "keys")

    @property
    def site(self):
        # An OAuth authorization carries its own region (the `domain` returned
        # at consent); API-key mode uses the configured site.
        if self.auth_mode() == "oauth" and self.cfg.get("oauth_domain"):
            return self.cfg["oauth_domain"]
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
        # lastpass mode: retrieve from secure note
        if self.auth_mode() == "lastpass":
            lp = self.cfg.get("lastpass", {})
            entry = lp.get("entry", "")
            if entry:
                api = lpass_get(entry, lp.get("api_key_field", "datadogAPIKey")) or api
                app = lpass_get(entry, lp.get("app_key_field", "datadogAPPKey")) or app
            return api, app
        # password-manager commands win when configured
        api = secret_from_cmd(self.cfg.get("api_key_cmd")) or api
        app = secret_from_cmd(self.cfg.get("app_key_cmd")) or app
        return api, app

    def has_keys(self):
        api, app = self._keys()
        return bool(api and app)

    # -------------------- OAuth (authorization-code + PKCE) --------------------

    def _oauth_blob(self):
        raw = (keychain_get("datadog-assistant-oauth")
               or self.cfg.get("oauth_blob", ""))
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def _save_oauth_blob(self, blob):
        raw = json.dumps(blob)
        if not keychain_set("datadog-assistant-oauth", raw):
            self.cfg["oauth_blob"] = raw  # non-Keychain fallback

    def configured(self):
        """Are credentials present for the active auth mode?"""
        if self.auth_mode() == "oauth":
            return bool(self.cfg.get("oauth_client_id")
                        and self._oauth_blob().get("refresh_token"))
        if self.auth_mode() == "lastpass":
            lp = self.cfg.get("lastpass", {})
            return bool(lp.get("entry")) and lpass_logged_in()
        return self.has_keys()

    def _oauth_api(self):
        # Token endpoint is regional; once connected we know the org's domain.
        return self.cfg.get("oauth_domain") or self.cfg.get("site", "datadoghq.com")

    def _access_token(self):
        """A valid OAuth access token (TTL ~1h), refreshed via the rotating
        refresh token when the cached one is about to expire."""
        if self._access["token"] and time.time() < self._access["expires"] - 60:
            return self._access["token"]
        blob = self._oauth_blob()
        data = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "client_id": self.cfg.get("oauth_client_id", ""),
            "client_secret": blob.get("client_secret", ""),
            "refresh_token": blob.get("refresh_token", ""),
        }).encode()
        req = urllib.request.Request(
            f"https://api.{self._oauth_api()}/oauth2/v1/token",
            data=data, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                tok = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"Datadog OAuth refresh failed ({e.code}): "
                f"{http_error_detail(e)} — reconnect via Preferences") from e
        self._access = {"token": tok["access_token"],
                        "expires": time.time() + int(tok.get("expires_in", 3600))}
        if tok.get("refresh_token"):  # Datadog rotates refresh tokens
            blob["refresh_token"] = tok["refresh_token"]
            self._save_oauth_blob(blob)
        return self._access["token"]

    def _request(self, method, path, params=None, body=None, version="v1"):
        oauth = self.auth_mode() == "oauth"
        api = app = ""
        if oauth:
            token = self._access_token()  # may raise -> surfaced as error row
        else:
            api, app = self._keys()
        url = f"https://api.{self.site}/api/{version}" + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        last_err = None
        for attempt in range(3):
            req = urllib.request.Request(url, data=data, method=method)
            if oauth:
                req.add_header("Authorization", "Bearer " + token)
            else:
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
        tag_filter = self.cfg.get("tag_filter", "").strip()
        name_filter = self.cfg.get("name_filter", "").strip()
        tags = tag_filter.split() if tag_filter else []

        # Datadog's monitor_tags param is AND logic. For OR, we fetch per tag
        # and dedupe by monitor ID.
        if len(tags) > 1:
            seen = {}
            for tag in tags:
                for m in self._fetch_monitors_page(monitor_tags=tag, name=name_filter):
                    seen.setdefault(m["id"], m)
            return list(seen.values())
        return self._fetch_monitors_page(
            monitor_tags=tags[0] if tags else "", name=name_filter)

    def _fetch_monitors_page(self, monitor_tags="", name=""):
        params = {"group_states": "all", "page_size": 200}
        if monitor_tags:
            params["monitor_tags"] = monitor_tags
        if name:
            params["name"] = name
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

    def get_orgs(self):
        return self._request("GET", "/org").get("orgs") or []

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

    def service_url(self, service):
        return f"{self.app_base}/services/{urllib.parse.quote(service)}"

    def event_url(self, event_id):
        return f"{self.app_base}/event/event?id={event_id}"

    def get_service_definitions(self):
        """Software Catalog service definitions (paginated) — the canonical
        home of a service's repo/runbook/docs/on-call links inside Datadog.
        schema_version=v2.2 returns the unified `links[]` shape."""
        out, page = [], 0
        while True:
            data = self._request("GET", "/services/definitions",
                                 params={"page[size]": 100, "page[number]": page,
                                         "schema_version": "v2.2"},
                                 version="v2")
            batch = data.get("data") or []
            out.extend(batch)
            if len(batch) < 100:
                return out
            page += 1

    def get_events(self, tags, start, end, sources=None):
        params = {"start": int(start), "end": int(end)}
        if tags:
            params["tags"] = ",".join(tags)
        if sources:
            params["sources"] = ",".join(sources)
        return self._request("GET", "/events", params=params).get("events") or []


def jira_label(s):
    """Jira labels can't contain spaces (and ':' reads badly in JQL) —
    normalize 'team:payments' → 'team-payments'."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", s.strip()).strip("-")


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
# Jira client (Cloud REST v3)
#
# Two auth modes:
#   "token" — Atlassian API token + Basic auth against your site. Works with
#             Okta SSO since tokens authenticate directly against Atlassian.
#   "oauth" — OAuth 2.0 (3LO): you log in once in the browser (where the
#             Okta session lives), the app keeps a refresh token in the
#             Keychain and calls api.atlassian.com with Bearer tokens.
#             Use this when your admin BLOCKS API tokens.
# --------------------------------------------------------------------------

JIRA_OAUTH_AUTH_URL = "https://auth.atlassian.com/authorize"
JIRA_OAUTH_TOKEN_URL = "https://auth.atlassian.com/oauth/token"
JIRA_OAUTH_RESOURCES_URL = \
    "https://api.atlassian.com/oauth/token/accessible-resources"
JIRA_OAUTH_SCOPES = "read:jira-work write:jira-work read:jira-user offline_access"
JIRA_OAUTH_PORT = 8917  # must match the app's registered callback URL


class JiraClient:
    def __init__(self, cfg):
        self.cfg = cfg or {}
        self._access = {"token": "", "expires": 0}  # cached OAuth access token

    def enabled(self):
        return bool(self.cfg.get("enabled"))

    def auth_mode(self):
        return self.cfg.get("auth", "token")

    def _token(self):
        return (self.cfg.get("_lp_api_token")
                or secret_from_cmd(self.cfg.get("api_token_cmd"))
                or self.cfg.get("api_token")
                or keychain_get("datadog-assistant-jira-token"))

    def _oauth_blob(self):
        raw = (keychain_get("datadog-assistant-jira-oauth")
               or self.cfg.get("oauth_blob", ""))
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def _save_oauth_blob(self, blob):
        raw = json.dumps(blob)
        if not keychain_set("datadog-assistant-jira-oauth", raw):
            self.cfg["oauth_blob"] = raw  # non-Keychain fallback

    def configured(self):
        if self.auth_mode() == "oauth":
            return bool(self.cfg.get("oauth_client_id")
                        and self.cfg.get("cloud_id")
                        and self._oauth_blob().get("refresh_token"))
        return bool(self.cfg.get("base_url") and self.cfg.get("email")
                    and self._token())

    def _access_token(self):
        """Valid OAuth access token, refreshed via the (rotating) refresh
        token when the cached one is about to expire."""
        if self._access["token"] and time.time() < self._access["expires"] - 60:
            return self._access["token"]
        blob = self._oauth_blob()
        body = {"grant_type": "refresh_token",
                "client_id": self.cfg.get("oauth_client_id", ""),
                "client_secret": (self.cfg.get("_lp_client_secret")
                                  or blob.get("client_secret", "")),
                "refresh_token": blob.get("refresh_token", "")}
        req = urllib.request.Request(JIRA_OAUTH_TOKEN_URL,
                                     data=json.dumps(body).encode(),
                                     method="POST")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                tok = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"Jira OAuth refresh failed ({e.code}): "
                f"{http_error_detail(e)} — reconnect via Preferences") from e
        self._access = {"token": tok["access_token"],
                        "expires": time.time() + int(tok.get("expires_in", 3600))}
        if tok.get("refresh_token"):  # Atlassian rotates refresh tokens
            blob["refresh_token"] = tok["refresh_token"]
            self._save_oauth_blob(blob)
        return self._access["token"]

    def _request(self, method, path, params=None, body=None):
        if self.auth_mode() == "oauth":
            url = (f"https://api.atlassian.com/ex/jira/"
                   f"{self.cfg.get('cloud_id', '')}" + path)
        else:
            url = self.cfg["base_url"].rstrip("/") + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if self.auth_mode() == "oauth":
            req.add_header("Authorization", "Bearer " + self._access_token())
        else:
            raw = f"{self.cfg.get('email', '')}:{self._token()}".encode()
            req.add_header("Authorization",
                           "Basic " + base64.b64encode(raw).decode())
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

    def list_projects(self):
        """(key, name) of projects visible to this token."""
        data = self._request("GET", "/rest/api/3/project/search",
                             params={"maxResults": 50, "orderBy": "key"})
        return [(p.get("key", ""), p.get("name", ""))
                for p in data.get("values", [])]

    def project_exists(self, key):
        """Targeted check — list_projects caps at 50, this doesn't."""
        data = self._request("GET", "/rest/api/3/project/search",
                             params={"keys": key})
        return any(p.get("key") == key for p in data.get("values", []))

    def whoami(self):
        """Who does Jira think this token is? Empty project lists +
        'project does not exist' usually mean the wrong account's token."""
        return self._request("GET", "/rest/api/3/myself")

    def create_issue(self, monitor_id, name, dd_url, context="",
                     extra_labels=None):
        text = f"Datadog monitor alert: {name}\n\n{dd_url}"
        if context:
            text += f"\n\nContext at creation: {context}"
        labels = list(dict.fromkeys(            # dedupe, keep order
            list(self.cfg.get("labels", []))
            + list(extra_labels or [])
            + [f"dd-monitor-{monitor_id}"]))
        body = {"fields": {
            "project": {"key": self.cfg.get("project_key", "OPS")},
            "issuetype": {"name": self.cfg.get("issue_type", "Task")},
            "summary": f"[Datadog] 🔴 {name}"[:254],
            "labels": labels,
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


def ask_choice(title, message, choices):
    """Blocking button chooser (max 3 — macOS alert limit). Returns the
    clicked label, '' on cancel/timeout. osascript-based, so unlike
    rumps.Window it is safe to call from any thread."""
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    btns = ", ".join(f'"{esc(c)}"' for c in choices)
    script = (f'display alert "{esc(title)}" message "{esc(message)}" '
              f'buttons {{{btns}}} default button "{esc(choices[-1])}"')
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=600)
        m = re.search(r"button returned:(.*)$", (out.stdout or "").strip())
        return m.group(1).strip() if m else ""
    except Exception:
        return ""


def ask_text(title, message, default="", secure=False, ok="Next"):
    """Blocking one-field input dialog. Returns the text ('' allowed) or
    None on cancel. osascript-based — safe from any thread."""
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    script = (f'display dialog "{esc(message)}" with title "{esc(title)}" '
              f'default answer "{esc(default)}" '
              f'buttons {{"Cancel", "{esc(ok)}"}} default button "{esc(ok)}"')
    if secure:
        script += " with hidden answer"
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=600)
    except Exception:
        return None
    if out.returncode != 0:
        return None  # Cancel (osascript exits 1 on "User canceled")
    m = re.search(r"text returned:(.*)$", (out.stdout or "").rstrip("\n"))
    return m.group(1).strip() if m else None


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
        # If using LastPass auth, auto-wire Jira OAuth credentials from the note
        lp = self.cfg.get("lastpass", {})
        jira_cfg = self.cfg.get("jira", {})
        if self.cfg.get("auth") == "lastpass" and lp.get("entry"):
            entry = lp["entry"]
            # Jira OAuth client ID
            if lp.get("jira_client_id_field"):
                cid = lpass_get(entry, lp["jira_client_id_field"])
                if cid:
                    jira_cfg["oauth_client_id"] = cid
            # Jira OAuth client secret — in-memory only, never persisted
            if lp.get("jira_client_secret_field"):
                sec = lpass_get(entry, lp["jira_client_secret_field"])
                if sec:
                    jira_cfg["_lp_client_secret"] = sec
            # Jira API token (non-OAuth fallback)
            if lp.get("jira_token_field"):
                tok = lpass_get(entry, lp["jira_token_field"])
                if tok:
                    jira_cfg["_lp_api_token"] = tok
        self.jira = JiraClient(jira_cfg)
        icons = self.cfg["icons"]
        super().__init__(APP_NAME, title=icons["ok"], quit_button=None)

        self.monitors = []
        self.incidents = []
        self.dashboards = []
        self.enrich = {}             # monitor id -> {spark, now, crit}
        self.nodata_probe = {}       # monitor id -> "stopped" | "silent"
        self.services = {}           # service name -> parsed Software Catalog entry
        self.deploys = {}            # monitor id -> {events, headline, suspect_url}
        self._deploy_cache = {}      # service -> (ts, events)  (shared across monitors)
        self._svc_ts = 0             # last Software Catalog refresh
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
        if self._refresh_item is not None:
            self._refresh_item.title = "⏳ Refreshing…"
        threading.Thread(target=self._fetch, daemon=True).start()

    def _fetch(self):
        try:
            if not self.client.configured():
                if self.client.auth_mode() == "oauth":
                    self.results.put(("error",
                                      "Datadog OAuth not connected — "
                                      "Preferences → 🔐 Datadog credentials"))
                elif self.cfg.get("api_key_cmd") or self.cfg.get("app_key_cmd"):
                    self.results.put(("error",
                                      "Secret command returned nothing — "
                                      "is your password manager unlocked?"))
                else:
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
                scfg = self.cfg.get("service_context", {})
                if scfg.get("enabled", True):
                    if scfg.get("use_catalog", True) and \
                            time.time() - self._svc_ts > 3600:
                        try:
                            defs = self.client.get_service_definitions()
                            payload["services"] = {
                                d["name"]: d for d in
                                (parse_service_definition(x) for x in defs) if d}
                            self._svc_ts = time.time()
                        except Exception:
                            pass  # key lacks catalog scope — links still come
                                  # from tags + the monitor message
                    if scfg.get("show_deploys", True):
                        payload["deploys"] = self._fetch_deploys(payload["monitors"])
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
                if "services" in payload:
                    self.services = payload["services"]
                if "deploys" in payload:
                    self.deploys = payload["deploys"]
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
            (m.get("id") or 0, self._display_name(m), m.get("overall_state") or "",
             parse_priority(m) or 0,
             bool((m.get("options") or {}).get("silenced")),
             len(self._triggered_groups(m)),
             self._is_dlq(m),
             self._triage_no_data(m)[0]
             if m.get("overall_state") == "No Data" else "")
            for m in self.monitors))
        enr = tuple(sorted(
            (k, v.get("spark"), v.get("now")) for k, v in self.enrich.items()))
        dep = tuple(sorted((k, v.get("sig")) for k, v in self.deploys.items()))
        svc = tuple(sorted(self.services.keys()))
        inc = tuple((i.get("public_id"), i.get("title"), i.get("severity"))
                    for i in self.incidents)
        dash = tuple(d["title"] for d in self.dashboards)
        # while anything is firing, refresh at most every 5 min anyway so
        # the "triggered Xm ago" rows don't go stale
        hot = any(m.get("overall_state") in ("Alert", "Warn", "No Data")
                  for m in self.monitors)
        bucket = int(time.time() // 300) if hot else 0
        return (self.last_error, time.time() < self.snooze_until,
                mons, enr, dep, svc, inc, dash, bucket)

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
                thr = ((m.get("options") or {}).get("thresholds") or {}).get("critical")
                out[m["id"]] = {"spark": sparkline(points),
                                "now": max(lasts) if lasts else None,
                                "crit": thr}
            except Exception:
                continue
        return out

    # ---------------- service context: repos, deploys, runbooks ------------

    def _alert_start(self, m):
        dur = self._alert_duration(m)
        return time.time() - dur if dur else None

    def _service_links(self, m):
        """Aggregate every repo/runbook/doc/dashboard link Datadog knows for a
        monitor — Software Catalog + tags + message — with no network call.
        Each source is a fallback so non-uniform monitors still surface what
        they can."""
        scfg = self.cfg.get("service_context", {})
        svc, how = resolve_service(m)
        links = {"repo": [], "runbook": [], "doc": [], "dashboard": [], "other": []}
        team, oncall = None, []
        if scfg.get("use_catalog", True) and svc:
            entry = self.services.get(svc) or self.services.get(svc.lower())
            if entry:
                team = entry.get("team")
                oncall = entry.get("oncall") or []
                for k in links:
                    links[k].extend(entry["links"].get(k, []))
        team = team or team_from_monitor(m)        # tag/@team fallback
        git = git_meta_from_monitor(m)
        for url in repo_urls_from_tags(m.get("tags")):
            links["repo"].append({"label": "tag", "url": url})
        if scfg.get("use_message_links", True):
            for ln in extract_message_links(m.get("message")):
                bucket = ln["kind"] if ln["kind"] in links else "other"
                links[bucket].append({"label": ln["label"], "url": ln["url"]})
        for k in links:                       # dedupe by url, keep order
            seen, ded = set(), []
            for it in links[k]:
                if it["url"] in seen:
                    continue
                seen.add(it["url"])
                ded.append(it)
            links[k] = ded
        # a commit link from git.repository_url + git.commit.sha tags
        commit = None
        if git["sha"] and links["repo"]:
            commit = commit_url(links["repo"][0]["url"], git["sha"])
        return {"service": svc, "service_how": how, "team": team,
                "oncall": oncall, "links": links,
                "version": version_from_monitor(m), "git": git, "commit": commit}

    def _fetch_deploys(self, monitors):
        """Recent deploy events per firing service (cached + capped), each
        tagged with a correlation headline when it shipped before the alert."""
        scfg = self.cfg.get("service_context", {})
        show_on = set(scfg.get("show_on", ["Alert", "Warn", "No Data"]))
        ttl = int(scfg.get("cache_seconds", 180))
        budget = int(scfg.get("max_services_per_poll", 6))
        lookback = int(scfg.get("lookback_hours", 24)) * 3600
        keywords = scfg.get("deploy_keywords", [])
        sources = scfg.get("deploy_event_sources") or None
        now = time.time()
        targets = [(m, service_from_monitor(m)) for m in monitors
                   if m.get("overall_state") in show_on]
        targets = [(m, s) for m, s in targets if s]
        targets.sort(key=lambda ms: parse_priority(ms[0]) or 9)

        out = {}
        for m, svc in targets:
            cached = self._deploy_cache.get(svc)
            if not (cached and now - cached[0] < ttl):
                if budget <= 0 and not cached:
                    continue
                if budget > 0:
                    try:
                        evs = self.client.get_events(
                            [f"service:{svc}"], now - lookback, now, sources)
                    except Exception:
                        evs = []
                    parsed = [{"title": (e.get("title")
                                         or (e.get("text") or "")[:80] or "deploy"),
                               "when": e.get("date_happened"),
                               "url": self.client.event_url(e.get("id"))}
                              for e in evs if is_deploy_event(e, keywords)]
                    parsed.sort(key=lambda x: x["when"] or 0, reverse=True)
                    cached = (now, parsed[:6])
                    self._deploy_cache[svc] = cached
                    budget -= 1
            evs = cached[1] if cached else []
            out[m.get("id")] = self._deploy_context_for(m, svc, evs)
        live = {s for _, s in targets}
        self._deploy_cache = {k: v for k, v in self._deploy_cache.items()
                              if k in live}
        return out

    def _deploy_context_for(self, m, svc, events):
        scfg = self.cfg.get("service_context", {})
        window = int(scfg.get("correlate_minutes", 120)) * 60
        start = self._alert_start(m)
        headline, suspect = None, self.client.service_url(svc)
        for e in events:
            w = e.get("when")
            if start and w and 0 <= start - w <= window:
                mins = int((start - w) / 60)
                headline = (f"🚀 Deploy “{e['title'][:40]}” "
                            f"{mins}m before this alert")
                suspect = e.get("url") or suspect
                break
        sig = "|".join([svc, headline or "",
                        str(events[0]["when"]) if events else ""])
        return {"service": svc, "events": events, "headline": headline,
                "suspect_url": suspect, "sig": sig}

    def _deploy_headline(self, mid):
        ctx = self.deploys.get(mid)
        return ctx.get("headline") if ctx else None

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
            name = self._display_name(m)
            url = self.client.monitor_url(mid)
            muted = bool((m.get("options") or {}).get("silenced"))

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
                dep_hint = (self._deploy_headline(mid)
                            if self.cfg.get("service_context", {}).get(
                                "notify_correlation", True) else None)
                if style in ("banner", "both"):
                    banner_body = f"{body} — {ctx}" if ctx else body
                    if dep_hint:
                        banner_body += f"\n{dep_hint}"
                    notify_banner(title, "Datadog Assistant 🐶", banner_body, sound)
                if style in ("modal", "both") and state == "Alert":
                    modal_body = body + (f"\n{ctx}" if ctx else "")
                    grps = self._triggered_groups(m)
                    if grps:
                        modal_body += "\n" + ", ".join(grps[:5])
                    if dep_hint:
                        modal_body += f"\n{dep_hint}"
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

    def _monitor_auto_labels(self, m):
        """datadog-alert-<tag> per monitor tag, so one shared config routes
        tickets to each team's board (filter: labels = datadog-alert-team-x)
        without per-ticket label customisation. If a tag_filter is set, only
        those tags are used; otherwise every monitor tag becomes a label."""
        if not self.cfg["jira"].get("auto_label_from_tags", True):
            return []
        tags = m.get("tags") or []
        flt = set(self.cfg.get("tag_filter", "").split())
        if flt:
            tags = [t for t in tags if t in flt]
        return [jira_label(f"datadog-alert-{t}") for t in tags]

    def _create_jira(self, m, auto=False):
        mid, name = m.get("id"), m.get("name", "")
        url = self.client.monitor_url(mid)
        ctx = self._context_line(m)
        auto_labels = self._monitor_auto_labels(m)

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
                key = self.jira.create_issue(mid, name, url, ctx, auto_labels)
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

    def _bucket_of(self, m):
        """Which display group a monitor belongs in, by mute/state/triage."""
        if bool((m.get("options") or {}).get("silenced")):
            return "Muted"
        state = m.get("overall_state", "Unknown")
        if state == "No Data":
            verdict, _ = self._triage_no_data(m)
            return "Quiet" if verdict == "quiet" else "No Data"
        if state in ("Alert", "Warn", "OK"):
            return state
        return "OK"

    def _grouped(self):
        groups = {"Alert": [], "Warn": [], "No Data": [], "Quiet": [],
                  "OK": [], "Muted": []}
        for m in self.monitors:
            groups[self._bucket_of(m)].append(m)
        return groups

    # -------------------- local renames & DLQ grouping --------------------

    def _aliases(self):
        return self.state.setdefault("aliases", {})

    def _display_name(self, m):
        """The monitor's name as shown in the menu — a local rename if the
        user set one, otherwise the real Datadog name. Renames never touch DD."""
        mid = m.get("id")
        alias = self._aliases().get(str(mid))
        return alias or m.get("name", f"monitor {mid}")

    def _is_dlq(self, m):
        dcfg = self.cfg.get("dlq", {})
        if not dcfg.get("enabled", True):
            return False
        pats = [p.lower() for p in dcfg.get("patterns", []) if p]
        if not pats:
            return False
        hay = [m.get("name") or "", self._display_name(m)]
        if dcfg.get("match_query", True):
            hay.append(m.get("query") or "")
        if dcfg.get("match_tags", True):
            hay.extend(str(t) for t in (m.get("tags") or []))
        blob = " ".join(hay).lower()
        return any(p in blob for p in pats)

    def _dlq_monitors(self):
        mons = [m for m in self.monitors if self._is_dlq(m)]
        mons.sort(key=lambda m: (SEV_RANK.get(self._bucket_of(m), 9),
                                 self._display_name(m).lower()))
        return mons

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
        dlq_all = self._dlq_monitors()
        dlq_exclusive = bool(self.cfg.get("dlq", {}).get("exclusive", True))
        dlq_ids = {m.get("id") for m in dlq_all} if dlq_exclusive else set()
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
            if dlq_all:
                summary += f" · 💀 {len(dlq_all)} dlq"
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

        # ---- dead letter queues (consolidated, severity-sorted) ----
        if dlq_all:
            urgent = [m for m in dlq_all
                      if self._bucket_of(m) in ("Alert", "Warn", "No Data")]
            healthy = [m for m in dlq_all if m not in urgent]
            badge = ""
            n_alert = sum(1 for m in dlq_all if self._bucket_of(m) == "Alert")
            if n_alert:
                badge = f" · {n_alert} alerting 🔴"
            items.append(rumps.MenuItem(
                f"{GROUP_HEADERS['DLQ']} ({len(dlq_all)}){badge}"))
            for m in urgent:
                items.append(self._monitor_item(m, self._bucket_of(m), seen))
            if healthy:
                sub = rumps.MenuItem(f"🟢 healthy ({len(healthy)})")
                sub_seen = set()
                for m in healthy:
                    sub.add(self._monitor_item(m, self._bucket_of(m), sub_seen))
                items.append(sub)
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
            monitors = [m for m in g.get(group, [])
                        if m.get("id") not in dlq_ids]
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
        dd_name = m.get("name", f"monitor {mid}")
        name = self._display_name(m)
        renamed = name != dd_name
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
            self._add_service_section(item, m, mid)
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
        item.add(rumps.MenuItem("✏️ Rename (local only)…",
                                callback=self._make_renamer(mid, dd_name)))
        if renamed:
            item.add(rumps.MenuItem(f"↩️ Reset to Datadog name “{dd_name[:30]}”",
                                    callback=self._make_alias_resetter(mid)))
        item.add(rumps.MenuItem("🗑 Delete monitor…",
                                callback=self._make_deleter(mid, dd_name)))
        return item

    def _add_service_section(self, item, m, mid):
        """The 🧭 panel: a prime-suspect deploy headline (if one shipped just
        before the alert) + a submenu of repo / deploys / runbook / docs /
        dashboard / on-call links, all sourced from Datadog itself."""
        if not self.cfg.get("service_context", {}).get("enabled", True):
            return
        info = self._service_links(m)
        dep = self.deploys.get(mid)
        has_links = any(info["links"].values()) or info["oncall"]
        if not info["service"] and not has_links:
            # nothing resolved — say why, so non-uniform monitors aren't a
            # silent blank (the user can then add a service:/team: tag)
            if self.cfg.get("service_context", {}).get("show_unresolved_hint", True):
                item.add(rumps.MenuItem(
                    "🧭 No service/repo found — add a service: or "
                    "git.repository_url: tag"))
            return
        if dep and dep.get("headline"):
            item.add(rumps.MenuItem(f"⚠️ {dep['headline']}",
                                    callback=self._make_opener(dep.get("suspect_url"))))
        item.add(self._service_submenu(info, dep))

    def _service_submenu(self, info, dep):
        svc = info["service"] or "service"
        title = f"🧭 {svc}" + (f" · {info['team']}" if info.get("team") else "")
        sub = rumps.MenuItem(title)
        seen = set()
        links = info["links"]
        if info.get("service") and info.get("service_how") not in (None, "tag"):
            sub.add(rumps.MenuItem(f"   (matched via {info['service_how']})"))

        def add_links(emoji, bucket, label):
            for it in links.get(bucket, [])[:3]:
                t = f"{emoji} {label}: {it['label']}"[:62]
                sub.add(rumps.MenuItem(unique_title(t, seen),
                                       callback=self._make_opener(it["url"])))

        add_links("📦", "repo", "Repo")
        git = info.get("git") or {}
        if info.get("version") or git.get("sha"):
            ver = info.get("version") or ""
            sha = f" · {git['sha'][:7]}" if git.get("sha") else ""
            brc = f" @ {git['branch']}" if git.get("branch") else ""
            label = f"🔖 {('version ' + ver) if ver else 'commit'}{sha}{brc}"
            if info.get("commit"):
                sub.add(rumps.MenuItem(unique_title(label[:62], seen),
                                       callback=self._make_opener(info["commit"])))
            else:
                sub.add(rumps.MenuItem(label[:62]))
        if dep and dep.get("events"):
            sub.add(rumps.MenuItem("🚀 Recent deploys"))
            for e in dep["events"][:4]:
                t = f"   🚀 {e['title']} · {fmt_ago(e['when'])}"[:62]
                sub.add(rumps.MenuItem(unique_title(t, seen),
                                       callback=self._make_opener(e["url"])))
        add_links("📕", "runbook", "Runbook")
        add_links("📖", "doc", "Docs")
        add_links("📊", "dashboard", "Dashboard")
        for oc in info.get("oncall", [])[:2]:
            sub.add(rumps.MenuItem(unique_title(f"📟 On-call: {oc['label']}", seen),
                                   callback=self._make_opener(oc["url"])))
        add_links("🔗", "other", "Link")
        if info["service"]:
            sub.add(None)
            sub.add(rumps.MenuItem("🔗 Open in Software Catalog",
                                   callback=self._make_opener(
                                       self.client.service_url(info["service"]))))
        return sub

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
        dlq = rumps.MenuItem("💀 Group dead letter queues",
                             callback=self._toggle_dlq)
        dlq.state = 1 if self.cfg.get("dlq", {}).get("enabled", True) else 0
        prefs.add(dlq)
        svc = rumps.MenuItem("🧭 Service & deploy context",
                             callback=self._toggle_service_context)
        svc.state = 1 if self.cfg.get("service_context", {}).get("enabled", True) else 0
        prefs.add(svc)
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
        prefs.add(rumps.MenuItem("🎫 Test Jira connection",
                                 callback=self._test_jira))
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
        prefs.add(rumps.MenuItem("🏢 Company subdomain…",
                                 callback=self._set_subdomain))
        prefs.add(rumps.MenuItem("🔐 Datadog credentials…",
                                 callback=self._edit_datadog_creds))
        prefs.add(rumps.MenuItem("🔐 Test Datadog connection",
                                 callback=self._test_datadog))

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

    def _make_renamer(self, mid, dd_name):
        def cb(_):
            current = self._aliases().get(str(mid), dd_name)
            win = rumps.Window(
                title="✏️ Rename monitor (local only)",
                message=(f'Datadog name:\n"{dd_name}"\n\n'
                         "Your label shows only in this app — Datadog is "
                         "untouched. Leave blank to reset."),
                default_text=current, ok="Save", cancel="Cancel",
                dimensions=(320, 24))
            resp = win.run()
            if not resp.clicked:
                return
            new = resp.text.strip()
            aliases = self._aliases()
            if not new or new == dd_name:
                aliases.pop(str(mid), None)
            else:
                aliases[str(mid)] = new
            save_state(self.state)
            self._rebuild_menu()
        return cb

    def _make_alias_resetter(self, mid):
        def cb(_):
            self._aliases().pop(str(mid), None)
            save_state(self.state)
            self._rebuild_menu()
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

    def _toggle_dlq(self, _):
        self._toggle("dlq", "enabled")

    def _toggle_service_context(self, _):
        on = not self.cfg.get("service_context", {}).get("enabled", True)
        self._toggle("service_context", "enabled")
        if on:
            self._svc_ts = 0          # force a catalog refresh on the next poll
            self._poll_tick(None)

    def _toggle_incidents(self, _):
        self._toggle("context", "show_incidents")

    def _toggle_sparkline(self, _):
        self._toggle("context", "show_sparkline")

    def _toggle_dashboards(self, _):
        self._toggle("context", "auto_dashboard_links")

    def _toggle_jira(self, _):
        if self.cfg["jira"].get("enabled", False):
            self._toggle("jira", "enabled", default=False)   # switch off
            self.jira = JiraClient(self.cfg.get("jira", {}))
            return
        if self.jira.configured():
            self._toggle("jira", "enabled", default=False)   # switch on
            self.jira = JiraClient(self.cfg.get("jira", {}))
            notify_banner("🎫 Jira enabled", "Datadog Assistant 🐶",
                          "Create tickets from any alert's submenu")
            return
        self._jira_setup()  # unconfigured — wizard enables on success

    def _edit_jira(self, _):
        self._jira_setup()

    def _test_jira(self, _):
        threading.Thread(target=self._jira_connection_test, daemon=True).start()

    # -------------------- Jira setup wizard --------------------

    def _jira_setup(self):
        """One wizard for both auth methods: pick token vs OAuth, run the
        matching credential steps, then the shared ticket-field steps
        (project/type/labels) once auth actually works."""
        choice = ask_choice(
            "🎫 Jira setup",
            "How should the app authenticate to Jira?\n\n"
            "API token — quickest. Needs a token from id.atlassian.com "
            "(works unless your org blocks API tokens).\n\n"
            "Okta / OAuth — you log in once in the browser instead; for "
            "orgs that block API tokens. Needs a one-time app registration "
            "at developer.atlassian.com (see README).",
            ["Cancel", "Okta / OAuth", "API token"])
        if choice == "API token":
            mode = "token"
        elif choice == "Okta / OAuth":
            mode = "oauth"
        else:
            return
        # background thread: the OAuth leg blocks on the browser redirect,
        # and ask_text/ask_choice are osascript-based so they don't need
        # the main thread
        threading.Thread(target=self._jira_setup_flow, args=(mode,),
                         daemon=True).start()

    def _jira_setup_flow(self, mode):
        jc = self.cfg["jira"]
        if mode == "token":
            for key, title, message, secret in [
                    ("base_url", "Jira base URL",
                     "e.g. https://yourcompany.atlassian.net", False),
                    ("email", "Atlassian account email",
                     "The email you log into Jira with", False),
                    ("api_token", "Jira API token",
                     "Create one at id.atlassian.com → Security → API "
                     "tokens.\nScoped tokens need read:jira-work, "
                     "write:jira-work, read:jira-user.\nStored in the macOS "
                     "Keychain. Leave blank to keep the current token.",
                     True)]:
                value = ask_text(f"🎫 Jira setup — {title}", message,
                                 default="" if secret else (jc.get(key) or ""),
                                 secure=secret)
                if value is None:
                    return  # cancelled
                if key == "api_token":
                    if not value:
                        continue  # keep whatever token is already stored
                    if keychain_set("datadog-assistant-jira-token", value):
                        jc["api_token"] = ""  # keychain wins
                    else:
                        jc[key] = value
                else:
                    jc[key] = value
            jc["auth"] = "token"
        else:
            client_id = ask_text(
                "🎫 Jira via Okta — Client ID",
                "One-time setup at developer.atlassian.com → Console →\n"
                "Create → OAuth 2.0 integration:\n"
                "• Permissions → Jira API → scopes read:jira-work,\n"
                "  write:jira-work, read:jira-user\n"
                "  (offline_access is requested automatically)\n"
                "• Authorization → callback URL exactly:\n"
                f"  http://localhost:{JIRA_OAUTH_PORT}/callback\n"
                "Paste the app's Client ID:",
                default=jc.get("oauth_client_id") or "")
            if not client_id:
                return
            secret = ask_text(
                "🎫 Jira via Okta — Client Secret",
                "From the same app's Settings page. Stored in the macOS\n"
                "Keychain. Your browser opens for the Okta login next.",
                secure=True, ok="Connect")
            if not secret:
                return
            jc["oauth_client_id"] = client_id
            save_config(self.cfg)
            if not self._jira_oauth_browser_flow(client_id, secret):
                return  # failure already explained in a modal
        save_config(self.cfg)
        if not self._jira_ticket_fields():
            return
        jc["enabled"] = True
        save_config(self.cfg)
        self.jira = JiraClient(jc)
        self._jira_connection_test()

    def _jira_ticket_fields(self):
        """Shared wizard tail: project, issue type, labels. Runs after
        credentials work in either mode, so the project list is real."""
        jc = self.cfg["jira"]
        proj_msg = "The ticket-number prefix — OPS for tickets like OPS-123."
        try:
            projs = JiraClient(jc).list_projects()
            if projs:
                shown = ", ".join(k for k, _ in projs[:15])
                if len(projs) > 15:
                    shown += f" … +{len(projs) - 15} more"
                proj_msg += f"\nYour projects: {shown}"
            else:
                proj_msg += ("\n⚠️ This login sees NO projects — wrong "
                             "Atlassian account, or no project access yet.")
        except Exception as e:
            proj_msg += f"\n⚠️ Couldn't list projects: {str(e)[:120]}"
        for key, title, message in [
                ("project_key", "Jira project key", proj_msg),
                ("issue_type", "Issue type",
                 "Must exist in your project: Task, Bug, Story…\n"
                 "(team-managed projects often don't have \"Task\")"),
                ("labels", "Ticket labels",
                 "Space- or comma-separated Jira labels added to every\n"
                 "ticket. Monitor tags are ALSO added automatically as\n"
                 "datadog-alert-<tag> (e.g. datadog-alert-team-payments),\n"
                 "so per-team routing usually needs nothing here.")]:
            if key == "labels":
                default = " ".join(jc.get("labels") or [])
            else:
                default = jc.get(key) or ""
            value = ask_text(f"🎫 Jira setup — {title}", message,
                             default=default)
            if value is None:
                return False
            if key == "labels":
                # Jira labels can't contain spaces, so both separators are safe
                jc["labels"] = [t for t in re.split(r"[,\s]+", value) if t]
            else:
                jc[key] = value
        save_config(self.cfg)
        return True

    def _jira_oauth_browser_flow(self, client_id, secret):
        state = base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("=")
        redirect = f"http://localhost:{JIRA_OAUTH_PORT}/callback"
        got = {}

        class Callback(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                got["code"] = (q.get("code") or [""])[0]
                got["state"] = (q.get("state") or [""])[0]
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write("<h2>🐶 Connected — close this tab and "
                                 "return to the menu bar.</h2>".encode())

            def log_message(self, *a):
                pass

        # Evict a previous attempt still parked on the port — the one-shot
        # server waits up to 4 min for a redirect that may never come (e.g.
        # the authorize page errored before redirecting).
        old = getattr(self, "_oauth_srv", None)
        if old is not None:
            old._cancelled = True
            try:
                old.server_close()
            except Exception:
                pass
            self._oauth_srv = None
        try:
            srv = http.server.HTTPServer(("127.0.0.1", JIRA_OAUTH_PORT), Callback)
        except OSError as e:
            notify_modal("❌ Jira OAuth failed",
                         f"Can't listen on port {JIRA_OAUTH_PORT}: {e}\n"
                         "Another app may be using it — or a previous "
                         "attempt is still waiting; try again in a few "
                         "minutes or restart Datadog Assistant.")
            return False
        srv._cancelled = False
        self._oauth_srv = srv
        srv.timeout = 240
        open_url(JIRA_OAUTH_AUTH_URL + "?" + urllib.parse.urlencode({
            "audience": "api.atlassian.com",
            "client_id": client_id,
            "scope": JIRA_OAUTH_SCOPES,
            "redirect_uri": redirect,
            "state": state,
            "response_type": "code",
            "prompt": "consent",
        }))
        try:
            srv.handle_request()  # one shot: blocks until redirect or timeout
        except Exception:
            pass  # socket yanked from under us by a newer attempt
        if getattr(srv, "_cancelled", False):
            return False  # superseded — the new attempt owns the port + modal
        try:
            srv.server_close()
        except Exception:
            pass
        self._oauth_srv = None
        if not got.get("code") or got.get("state") != state:
            notify_modal("❌ Jira OAuth failed",
                         "No authorization code received "
                         "(timed out or cancelled in the browser).")
            return False
        try:
            req = urllib.request.Request(
                JIRA_OAUTH_TOKEN_URL, method="POST",
                data=json.dumps({"grant_type": "authorization_code",
                                 "client_id": client_id,
                                 "client_secret": secret,
                                 "code": got["code"],
                                 "redirect_uri": redirect}).encode())
            req.add_header("Content-Type", "application/json")
            with urllib.request.urlopen(req, timeout=20) as resp:
                tok = json.loads(resp.read().decode())
            req = urllib.request.Request(JIRA_OAUTH_RESOURCES_URL)
            req.add_header("Authorization", "Bearer " + tok["access_token"])
            with urllib.request.urlopen(req, timeout=20) as resp:
                sites = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            notify_modal("❌ Jira OAuth failed",
                         f"{e.code}: {http_error_detail(e)}")
            return False
        except Exception as e:
            notify_modal("❌ Jira OAuth failed", str(e)[:300])
            return False
        if not sites:
            notify_modal("❌ Jira OAuth failed",
                         "This login has access to no Jira sites.")
            return False
        base = (self.cfg["jira"].get("base_url") or "").rstrip("/")
        site = next((s for s in sites
                     if s.get("url", "").rstrip("/") == base), sites[0])
        jc = self.cfg["jira"]
        jc["auth"] = "oauth"
        jc["cloud_id"] = site["id"]
        jc["base_url"] = site.get("url") or jc.get("base_url", "")
        JiraClient(jc)._save_oauth_blob({
            "client_secret": secret,
            "refresh_token": tok.get("refresh_token", "")})
        save_config(self.cfg)
        notify_banner("🎫 Jira connected via OAuth", "Datadog Assistant 🐶",
                      site.get("name") or site.get("url", ""))
        return True

    def _jira_connection_test(self):
        """Definitive who-am-I-and-what-can-I-see check. 'Project does not
        exist' + an empty project list = the token authenticates an identity
        without access (wrong Atlassian account, or admin-blocked tokens)."""
        client = JiraClient(self.cfg.get("jira", {}))
        try:
            me = client.whoami()
            projs = client.list_projects()
            pk = self.cfg["jira"].get("project_key", "")
            lines = [f"Connected as {me.get('displayName', '?')} "
                     f"({me.get('emailAddress') or 'email hidden'})"]
            if projs:
                lines.append(f"{len(projs)} project(s) visible")
            else:
                lines.append("⚠️ NO projects visible — token from the wrong "
                             "Atlassian account, or API tokens are blocked "
                             "by your admin")
            if pk:
                if client.project_exists(pk):
                    lines.append(f"✅ Project {pk} is accessible")
                else:
                    keys = ", ".join(k for k, _ in projs[:12]) or "none"
                    lines.append(f"❌ Project {pk} NOT accessible. "
                                 f"Visible keys: {keys}")
            notify_modal("🎫 Jira connection test", "\n".join(lines))
        except Exception as e:
            notify_modal("❌ Jira connection failed", str(e)[:300])

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
            message="Space-separated tags — monitors matching ANY tag are "
                    "shown (OR logic).\nLeave empty for all monitors.\n"
                    "Example: team:payments team:platform",
            default_text=self.cfg.get("tag_filter", ""),
            ok="Save", cancel="Cancel", dimensions=(320, 24))
        resp = win.run()
        if resp.clicked:
            self.cfg["tag_filter"] = resp.text.strip()
            save_config(self.cfg)
            # Clear stale data so the menu reflects the change immediately
            self.monitors = []
            self._fetching = False
            self._poll_tick(None)

    # -------------------- Datadog credentials wizard --------------------

    def _edit_datadog_creds(self, _):
        self._datadog_setup()

    def _test_datadog(self, _):
        threading.Thread(target=self._datadog_connection_test, daemon=True).start()

    def _datadog_setup(self):
        """One wizard for both auth methods: pick API keys vs OAuth vs
        LastPass, run the matching credential steps, then test."""
        choice = ask_choice(
            "🔐 Datadog credentials",
            "How should the app authenticate to Datadog?\n\n"
            "API + App keys — quickest. Create them at Organization "
            "Settings → API Keys / Application Keys (the app key needs the "
            "monitors_read / monitors_write / monitors_downtime scopes).\n\n"
            "OAuth — log in once in the browser; the app stores rotating "
            "tokens instead of your keys, and detects your region "
            "automatically. Needs a one-time OAuth client in Datadog "
            "(see README).\n\n"
            "LastPass CLI — fetch keys from a shared LastPass vault entry "
            "at runtime. No keys stored on disk.",
            ["Cancel", "LastPass CLI", "OAuth", "API + App keys"])
        if choice == "API + App keys":
            mode = "keys"
        elif choice == "OAuth":
            mode = "oauth"
        elif choice == "LastPass CLI":
            mode = "lastpass"
        else:
            return
        # Thread: OAuth blocks on browser redirect; osascript dialogs are safe off main thread.
        threading.Thread(target=self._datadog_setup_flow, args=(mode,),
                         daemon=True).start()

    def _datadog_setup_flow(self, mode):
        if mode == "keys":
            api = ask_text(
                "🔐 Datadog — API key",
                "Organization Settings → API Keys.\nStored in the macOS "
                "Keychain. Leave blank to keep the current key.",
                secure=True)
            if api is None:
                return
            if api:
                if keychain_set("datadog-assistant-api-key", api):
                    self.cfg["api_key"] = ""   # keychain wins
                else:
                    self.cfg["api_key"] = api
            app = ask_text(
                "🔐 Datadog — Application key",
                "Organization Settings → Application Keys. Needs the scopes "
                "monitors_read, monitors_write, monitors_downtime (plus "
                "dashboards_read / incident_read for the extras).\nStored in "
                "the macOS Keychain. Leave blank to keep the current key.",
                secure=True, ok="Save")
            if app is None:
                return
            if app:
                if keychain_set("datadog-assistant-app-key", app):
                    self.cfg["app_key"] = ""
                else:
                    self.cfg["app_key"] = app
            self.cfg["auth"] = "keys"
            self.cfg["use_keychain"] = True
            save_config(self.cfg)
        elif mode == "lastpass":
            # Check lpass is installed
            try:
                subprocess.run([_LPASS, "--version"], capture_output=True, timeout=5)
            except Exception:
                notify_modal("❌ LastPass CLI not found",
                             "Install it with: brew install lastpass-cli\n"
                             "Then re-run this setup.")
                return
            if not lpass_logged_in():
                notify_modal("⚠️ Not logged into LastPass",
                             "Run in Terminal:\n  lpass login your@email.com\n"
                             "Then re-run this setup.")
                return
            entry = ask_text(
                "🔐 LastPass — Entry name",
                "The full path to the shared entry, e.g.:\n"
                "  Shared-SRE/datadog-assistant\n\n"
                "This entry should have custom fields for the API keys.",
                default=self.cfg.get("lastpass", {}).get("entry", ""))
            if not entry:
                return
            api_field = ask_text(
                "🔐 LastPass — API Key field name",
                "The key name in the secure note that holds the "
                "Datadog API key (e.g. datadogAPIKey).",
                default=self.cfg.get("lastpass", {}).get("api_key_field", "datadogAPIKey"))
            if not api_field:
                return
            app_field = ask_text(
                "🔐 LastPass — App Key field name",
                "The key name in the secure note that holds the "
                "Datadog Application key (e.g. datadogAPPKey).",
                default=self.cfg.get("lastpass", {}).get("app_key_field", "datadogAPPKey"))
            if not app_field:
                return
            self.cfg["auth"] = "lastpass"
            self.cfg["lastpass"] = {
                "entry": entry,
                "api_key_field": api_field,
                "app_key_field": app_field,
            }
            save_config(self.cfg)
        else:
            client_id = ask_text(
                "🔐 Datadog OAuth — Client ID",
                "One-time setup: create an OAuth client in Datadog\n"
                "(Organization Settings → OAuth, or the Developer Platform):\n"
                "• Scopes: monitors_read, monitors_write,\n"
                "  monitors_downtime, dashboards_read, incident_read,\n"
                "  metrics_read, events_read\n"
                "• Redirect URI exactly:\n"
                f"  http://localhost:{DD_OAUTH_PORT}/callback\n"
                "Paste the client's Client ID:",
                default=self.cfg.get("oauth_client_id") or "")
            if not client_id:
                return
            secret = ask_text(
                "🔐 Datadog OAuth — Client Secret",
                "From the same OAuth client. Stored in the macOS Keychain.\n"
                "Your browser opens for the Datadog login next.",
                secure=True, ok="Connect")
            if not secret:
                return
            self.cfg["oauth_client_id"] = client_id
            save_config(self.cfg)
            if not self._datadog_oauth_browser_flow(client_id, secret):
                return  # failure already explained in a modal
            self.cfg["auth"] = "oauth"
            save_config(self.cfg)
        self.client = DatadogClient(self.cfg)
        self._datadog_connection_test()
        # Refetch with the new credentials; the main-thread drain timer
        # rebuilds the menu (mutating it from this worker thread is unsafe).
        self._poll_tick(None)

    def _datadog_oauth_browser_flow(self, client_id, secret):
        # PKCE: a high-entropy verifier and its S256 challenge.
        verifier = base64.urlsafe_b64encode(os.urandom(40)).decode().rstrip("=")
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        state = base64.urlsafe_b64encode(os.urandom(16)).decode().rstrip("=")
        redirect = f"http://localhost:{DD_OAUTH_PORT}/callback"
        site = self.cfg.get("site", "datadoghq.com")
        got = {}

        class Callback(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                got["code"] = (q.get("code") or [""])[0]
                got["state"] = (q.get("state") or [""])[0]
                # Datadog returns the org's region as `domain` on the redirect.
                got["domain"] = (q.get("domain") or [""])[0]
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write("<h2>🐶 Connected — close this tab and "
                                 "return to the menu bar.</h2>".encode())

            def log_message(self, *a):
                pass

        old = getattr(self, "_dd_oauth_srv", None)
        if old is not None:
            old._cancelled = True
            try:
                old.server_close()
            except Exception:
                pass
            self._dd_oauth_srv = None
        try:
            srv = http.server.HTTPServer(("127.0.0.1", DD_OAUTH_PORT), Callback)
        except OSError as e:
            notify_modal("❌ Datadog OAuth failed",
                         f"Can't listen on port {DD_OAUTH_PORT}: {e}\n"
                         "Another app may be using it — or a previous attempt "
                         "is still waiting; try again in a few minutes or "
                         "restart Datadog Assistant.")
            return False
        srv._cancelled = False
        self._dd_oauth_srv = srv
        srv.timeout = 240
        open_url(f"https://app.{site}/oauth2/v1/authorize?" +
                 urllib.parse.urlencode({
                     "client_id": client_id,
                     "redirect_uri": redirect,
                     "response_type": "code",
                     "code_challenge": challenge,
                     "code_challenge_method": "S256",
                     "scope": DD_OAUTH_SCOPES,
                     "state": state,
                 }))
        try:
            srv.handle_request()  # one shot: blocks until redirect or timeout
        except Exception:
            pass
        if getattr(srv, "_cancelled", False):
            return False  # superseded by a newer attempt
        try:
            srv.server_close()
        except Exception:
            pass
        self._dd_oauth_srv = None
        if not got.get("code") or got.get("state") != state:
            notify_modal("❌ Datadog OAuth failed",
                         "No authorization code received "
                         "(timed out or cancelled in the browser).")
            return False
        domain = got.get("domain") or site
        try:
            data = urllib.parse.urlencode({
                "grant_type": "authorization_code",
                "client_id": client_id,
                "client_secret": secret,
                "code": got["code"],
                "code_verifier": verifier,
                "redirect_uri": redirect,
            }).encode()
            req = urllib.request.Request(
                f"https://api.{domain}/oauth2/v1/token", data=data, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            with urllib.request.urlopen(req, timeout=20) as resp:
                tok = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            notify_modal("❌ Datadog OAuth failed",
                         f"{e.code}: {http_error_detail(e)}")
            return False
        except Exception as e:
            notify_modal("❌ Datadog OAuth failed", str(e)[:300])
            return False
        if not tok.get("refresh_token"):
            notify_modal("❌ Datadog OAuth failed",
                         "No refresh token returned — make sure the OAuth "
                         "client allows the authorization_code grant.")
            return False
        self.cfg["oauth_domain"] = domain
        DatadogClient(self.cfg)._save_oauth_blob({
            "client_secret": secret,
            "refresh_token": tok["refresh_token"]})
        save_config(self.cfg)
        notify_banner("🔐 Datadog connected via OAuth", "Datadog Assistant 🐶",
                      domain)
        return True

    def _datadog_connection_test(self):
        """Fetch monitors with the active credentials and report what worked —
        run this first when the menu bar shows 🔌."""
        client = DatadogClient(self.cfg)
        mode = {"oauth": "OAuth", "lastpass": "LastPass CLI"}.get(
            client.auth_mode(), "API + App keys")
        if not client.configured():
            notify_modal("❌ Datadog not configured",
                         f"Auth mode: {mode}\nNo credentials yet — run "
                         "Preferences → 🔐 Datadog credentials.")
            return
        try:
            mons = client.get_monitors()
            lines = [f"Auth: {mode}", f"Site: {client.site}",
                     f"✅ Fetched {len(mons)} monitor(s)"]
            try:
                client.get_incidents()
                lines.append("✅ Incidents accessible")
            except Exception:
                lines.append("ℹ️ Incidents not accessible "
                             "(needs the incident_read scope)")
            notify_modal("🔐 Datadog connection test", "\n".join(lines))
        except Exception as e:
            notify_modal("❌ Datadog connection failed",
                         f"Auth mode: {mode}\n{str(e)[:280]}")

    def _set_subdomain(self, _):
        threading.Thread(target=self._set_subdomain_flow, daemon=True).start()

    def _set_subdomain_flow(self):
        """Orgs with a custom subdomain (<company>.datadoghq.eu) get a login
        page from generic app.<site> links — the session cookie lives on the
        company host. The API doesn't expose the subdomain, so ask, with the
        org name (which usually matches) as a suggested guess."""
        cur = self.cfg.get("app_subdomain") or "app"
        guess = "" if cur == "app" else cur
        if not guess:
            try:
                orgs = self.client.get_orgs()
                if orgs:
                    guess = re.sub(r"[^a-z0-9-]+", "-",
                                   (orgs[0].get("name") or "").lower()).strip("-")
            except Exception:
                pass
        value = ask_text(
            "🏢 Datadog company subdomain",
            "If you normally browse <company>.datadoghq.eu, links must use\n"
            "that subdomain or Datadog asks you to log in again.\n"
            "Enter just the company part — the suggestion is a guess from\n"
            "your org name, so check your browser's address bar.\n"
            "Leave empty for the generic app.<site>.",
            default=guess, ok="Save")
        if value is None:
            return
        v = re.sub(r"^https?://", "", value.strip().lower()).split("/")[0]
        site = self.client.site
        if v.endswith("." + site):       # pasted the full host? take the prefix
            v = v[:-(len(site) + 1)]
        self.cfg["app_subdomain"] = v or "app"
        save_config(self.cfg)
        notify_banner("🌐 Links now use", "Datadog Assistant 🐶",
                      self.client.app_base)

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
