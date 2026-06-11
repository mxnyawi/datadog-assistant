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

import json
import os
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
    "Muted": "🔇",
    "Unknown": "❓",
    "Skipped": "⏭",
    "Ignored": "🙈",
}

GROUP_HEADERS = {
    "Alert": "🔴 ALERTING",
    "Warn": "🟡 WARNING",
    "No Data": "⚪ NO DATA",
    "OK": "🟢 OK",
    "Muted": "🔇 MUTED",
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


def keychain_get(service):
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=5
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


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
        return f"https://app.{self.site}"

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

    def _request(self, method, path, params=None, body=None):
        api, app = self._keys()
        url = self.api_base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("DD-API-KEY", api)
        req.add_header("DD-APPLICATION-KEY", app)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = resp.read().decode()
            return json.loads(payload) if payload else {}

    def get_monitors(self):
        params = {"group_states": "all", "page_size": 1000}
        tag_filter = self.cfg.get("tag_filter", "").strip()
        if tag_filter:
            params["monitor_tags"] = ",".join(tag_filter.split())
        name_filter = self.cfg.get("name_filter", "").strip()
        if name_filter:
            params["name"] = name_filter
        return self._request("GET", "/monitor", params=params)

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
                webbrowser.open(url)
        except Exception:
            pass

    threading.Thread(target=run, daemon=True).start()


# --------------------------------------------------------------------------
# The menu bar app
# --------------------------------------------------------------------------

class DatadogAssistant(rumps.App):
    def __init__(self):
        self.cfg = load_config()
        self.client = DatadogClient(self.cfg)
        icons = self.cfg["icons"]
        super().__init__(APP_NAME, title=icons["ok"], quit_button=None)

        self.monitors = []
        self.prev_states = {}        # id -> overall_state
        self.last_notified = {}      # id -> unix ts (for renotify)
        self.snooze_until = 0
        self.last_refresh = None
        self.last_error = None
        self.results = queue.Queue()
        self._fetching = False

        self.menu = self._build_static_menu()
        self._rebuild_menu()

        interval = max(15, int(self.cfg.get("refresh_seconds", 60)))
        self.poll_timer = rumps.Timer(self._poll_tick, interval)
        self.poll_timer.start()
        self.drain_timer = rumps.Timer(self._drain_results, 2)
        self.drain_timer.start()
        self._poll_tick(None)  # immediate first fetch

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
                monitors = self.client.get_monitors()
                self.results.put(("monitors", monitors))
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
            if kind == "monitors":
                self.last_error = None
                self.last_refresh = datetime.now()
                self._handle_new_monitors(payload)
            else:
                self.last_error = payload
            updated = True
        if updated:
            self._rebuild_menu()
            self._update_title()

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
                    should = True
                    title, body = "⚪ No Data — Datadog", name
                elif state == "OK" and prev in ("Alert", "Warn", "No Data") \
                        and ncfg.get("notify_on_recovery", True):
                    should = True
                    title, body = "🟢 Recovered — Datadog", name
            elif state == "Alert" and ncfg.get("renotify_minutes", 0):
                last = self.last_notified.get(mid, 0)
                if now - last > ncfg["renotify_minutes"] * 60:
                    should = True
                    title, body = "🔴 STILL ALERTING — Datadog", name

            self.prev_states[mid] = state

            if should and ncfg.get("enabled", True) and not snoozed and not muted:
                self.last_notified[mid] = now
                style = ncfg.get("style", "both")
                sound = ncfg.get("sound_name") if ncfg.get("sound", True) else None
                if style in ("banner", "both"):
                    notify_banner(title, "Datadog Assistant 🐶", body, sound)
                if style in ("modal", "both") and state == "Alert":
                    notify_modal(title, body, url)
                if sound and style == "modal":
                    play_sound(sound)

    # -------------------- title (menu bar icon) --------------------

    def _grouped(self):
        groups = {"Alert": [], "Warn": [], "No Data": [], "OK": [], "Muted": []}
        for m in self.monitors:
            muted = bool(m.get("options", {}).get("silenced"))
            state = m.get("overall_state", "Unknown")
            if muted:
                groups["Muted"].append(m)
            elif state in groups:
                groups[state].append(m)
            else:
                groups["OK"].append(m)
        return groups

    def _update_title(self):
        icons = self.cfg["icons"]
        if self.last_error:
            self.title = icons["error"]
            return
        if time.time() < self.snooze_until:
            self.title = icons["snoozed"]
            return
        g = self._grouped()
        if g["Alert"]:
            n = f" {len(g['Alert'])}" if icons.get("show_count", True) else ""
            self.title = f"{icons['alert']}{n}"
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
        items = []

        # ---- status header ----
        g = self._grouped()
        if self.last_error:
            items.append(rumps.MenuItem(f"🔌 Error: {self.last_error}"))
        else:
            summary = (
                f"📊 {len(g['Alert'])} alerting · {len(g['Warn'])} warn · "
                f"{len(g['OK'])} ok · {len(g['Muted'])} muted"
            )
            hdr = rumps.MenuItem(summary, callback=self._open_manage_monitors)
            items.append(hdr)

        ts = self.last_refresh.strftime("%H:%M:%S") if self.last_refresh else "never"
        items.append(rumps.MenuItem(f"🔄 Refresh now (last: {ts})",
                                    callback=self._manual_refresh, key="r"))
        if time.time() < self.snooze_until:
            until = datetime.fromtimestamp(self.snooze_until).strftime("%H:%M")
            items.append(rumps.MenuItem(f"😴 Snoozed until {until} — wake up",
                                        callback=self._unsnooze))
        items.append(None)  # separator

        # ---- monitor groups ----
        show_ok = self.cfg["menu"].get("show_ok_monitors", True)
        max_per = int(self.cfg["menu"].get("max_per_group", 25))
        for group in self.cfg["menu"].get("group_order",
                                          ["Alert", "Warn", "No Data", "OK", "Muted"]):
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
                    items.append(self._monitor_item(m, group))
            else:
                # collapsed into a submenu
                for m in monitors[:max_per]:
                    header.add(self._monitor_item(m, group))
                if len(monitors) > max_per:
                    header.add(rumps.MenuItem(f"… {len(monitors) - max_per} more"))
                items.append(header)
            items.append(None)

        # ---- actions ----
        items.append(rumps.MenuItem("➕ Add Monitor…", callback=self._add_monitor, key="n"))

        links = rumps.MenuItem("🔗 Quick Links")
        for link in self.cfg.get("quick_links", []):
            links.add(rumps.MenuItem(
                link["name"],
                callback=self._make_opener(self.client.app_base + link["path"])))
        custom = self.cfg.get("custom_links", [])
        if custom:
            links.add(None)
            for link in custom:
                links.add(rumps.MenuItem(link["name"],
                                         callback=self._make_opener(link["url"])))
        items.append(links)
        items.append(None)

        # ---- preferences ----
        items.append(self._prefs_menu())
        items.append(rumps.MenuItem("🩺 Test Notification", callback=self._test_notification))
        items.append(None)
        items.append(rumps.MenuItem("❌ Quit", callback=rumps.quit_application, key="q"))

        self.menu = items

    def _monitor_item(self, m, group):
        mid = m.get("id")
        name = m.get("name", f"monitor {mid}")
        emoji = STATE_EMOJI.get("Muted" if group == "Muted" else
                                m.get("overall_state", "Unknown"), "❓")
        label = f"{emoji} {name}"
        if len(label) > 60:
            label = label[:57] + "…"
        item = rumps.MenuItem(label)
        url = self.client.monitor_url(mid)
        item.add(rumps.MenuItem("🔗 Open in Datadog", callback=self._make_opener(url)))
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
            webbrowser.open(url)
        return cb

    def _open_manage_monitors(self, _):
        webbrowser.open(self.client.app_base + "/monitors/manage")

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
    DatadogAssistant().run()
