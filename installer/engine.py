"""Shared install engine for Datadog Assistant.

One place that knows how to set the app up, callable from:
  - the pywebview onboarding GUI (installer/onboarding/app.py), and
  - a headless/CLI entry (engine.py --headless, env-driven, for CI/agents).

So the GUI and the scripted path can't drift — the same problem PR #2 fixed
for install.sh, kept honest here by a single module.

Runs on Linux for unit testing: set DD_DRY_RUN=1 (or pass dry_run=True) to skip
every system mutation (venv/pip/keychain/launchctl/brew/lpass) while still
producing config.json and the LaunchAgent plist text, so the contract is
assertable without a Mac.

No GUI imports here — pure stdlib so it imports anywhere.
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# Paths / constants (match the historical installer so upgrades are in place)
# --------------------------------------------------------------------------
APP_DIR = os.path.expanduser("~/.datadog-assistant")
CONFIG_DIR = os.path.expanduser("~/.config/datadog-assistant")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
LABEL = "com.nour.datadog-assistant"
PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")

API_KEY_SERVICE = "datadog-assistant-api-key"
APP_KEY_SERVICE = "datadog-assistant-app-key"

# When packaged with py2app, sys.frozen is set and the app embeds its own
# Python + deps — so there's no venv/pip step and the LaunchAgent runs the
# bundle directly. As a plain script (dev / legacy) we fall back to the venv.
FROZEN = bool(getattr(sys, "frozen", False))


def _dry_run(flag=None):
    if flag is not None:
        return bool(flag)
    return os.environ.get("DD_DRY_RUN") == "1"


# --------------------------------------------------------------------------
# Environment detection (feeds the GUI's first screen)
# --------------------------------------------------------------------------
def find_python3():
    """A real (non-frozen) python3 to build the venv with (script mode only)."""
    for cand in ("python3", "/usr/bin/python3", "/usr/local/bin/python3",
                 "/opt/homebrew/bin/python3"):
        path = shutil.which(cand) if "/" not in cand else (
            cand if os.path.exists(cand) else None)
        if path:
            return path
    return None


def find_lpass():
    """Locate the lpass binary, incl. Homebrew paths a LaunchAgent's PATH misses."""
    for p in ("/opt/homebrew/bin/lpass", "/usr/local/bin/lpass"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("lpass") or ""


def find_brew():
    for p in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("brew") or ""


def lpass_logged_in(lpass=None):
    lpass = lpass or find_lpass()
    if not lpass:
        return False
    try:
        out = subprocess.run([lpass, "status"], capture_output=True,
                             text=True, timeout=10)
        return out.returncode == 0 and "Logged in" in out.stdout
    except Exception:
        return False


SITES = [
    {"label": "US1  ·  datadoghq.com", "value": "datadoghq.com"},
    {"label": "EU  ·  datadoghq.eu", "value": "datadoghq.eu"},
    {"label": "US3  ·  us3.datadoghq.com", "value": "us3.datadoghq.com"},
    {"label": "US5  ·  us5.datadoghq.com", "value": "us5.datadoghq.com"},
    {"label": "AP1  ·  ap1.datadoghq.com", "value": "ap1.datadoghq.com"},
    {"label": "GOV  ·  ddog-gov.com", "value": "ddog-gov.com"},
]


def detect_env():
    """What the onboarding UI needs to decide which paths to offer."""
    lpass = find_lpass()
    return {
        "sites": SITES,
        "defaults": {"site": "datadoghq.com", "app_subdomain": "app",
                     "tag_filter": ""},
        "env": {
            "has_homebrew": bool(find_brew()),
            "has_lpass": bool(lpass),
            "lpass_logged_in": lpass_logged_in(lpass),
            "frozen": FROZEN,
        },
        "app_version": "1.0.0",
    }


# --------------------------------------------------------------------------
# Datadog key validation
# --------------------------------------------------------------------------
def validate_datadog_keys(site, api_key, app_key, timeout=15):
    """Hit /api/v1/validate with the keys. Returns {ok, error?}."""
    if not api_key or not app_key:
        return {"ok": False, "error": "Both API and Application keys are required."}
    url = f"https://api.{site}/api/v1/validate"
    req = urllib.request.Request(url, headers={
        "DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode() or "{}")
        if body.get("valid"):
            return {"ok": True}
        return {"ok": False, "error": "Datadog rejected those keys (not valid)."}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {"ok": False, "error": "Invalid API or Application key."}
        return {"ok": False, "error": f"Datadog returned HTTP {e.code}."}
    except Exception as e:
        return {"ok": False, "error": f"Couldn't reach Datadog: {str(e)[:120]}"}


# --------------------------------------------------------------------------
# LastPass (GUI drives the CLI under the hood)
# --------------------------------------------------------------------------
def lastpass_ensure_cli(on_log=None):
    """Make sure `lpass` exists; install via Homebrew if we can. {installed, error?}."""
    log = on_log or (lambda *_: None)
    lpass = find_lpass()
    if lpass:
        return {"installed": True}
    brew = find_brew()
    if not brew:
        return {"installed": False,
                "error": "Homebrew isn't installed, so the LastPass CLI can't be "
                         "installed automatically. Install Homebrew from "
                         "https://brew.sh, then come back."}
    log("$ brew install lastpass-cli")
    try:
        p = subprocess.run([brew, "install", "lastpass-cli"],
                           capture_output=True, text=True, timeout=900)
        if p.stdout.strip():
            log(p.stdout.strip())
        if p.returncode != 0:
            return {"installed": False,
                    "error": (p.stderr.strip() or "brew install failed")[:300]}
    except Exception as e:
        return {"installed": False, "error": str(e)[:200]}
    return {"installed": bool(find_lpass())}


def lastpass_login(email, password, otp="", never_expire=True, on_log=None):
    """Non-interactive `lpass login`. If MFA is needed, returns
    {ok: False, mfa_required: True} so the GUI can collect an OTP and retry.

    The master password and OTP are passed via stdin/env, never argv or disk."""
    log = on_log or (lambda *_: None)
    lpass = find_lpass()
    if not lpass:
        return {"ok": False, "error": "LastPass CLI not found."}
    if not email or not password:
        return {"ok": False, "error": "Email and master password are required."}
    env = dict(os.environ)
    env["LPASS_DISABLE_PINENTRY"] = "1"
    # Start the agent with no timeout when the user wants to stay signed in, so
    # the menu-bar app inherits a session that won't lapse mid-day.
    env["LPASS_AGENT_TIMEOUT"] = "0" if never_expire else env.get(
        "LPASS_AGENT_TIMEOUT", "")
    # With LPASS_DISABLE_PINENTRY=1, lpass reads the master password from stdin.
    # It must arrive WITHOUT a trailing newline (the documented `printf '%s' …`
    # recipe) — a trailing "\n" gets read as part of the password and login
    # fails with "Failed to enter correct password". When an OTP is supplied,
    # the password line is newline-terminated so lpass can then read the code.
    stdin = (password + "\n" + otp + "\n") if otp else password
    log(f"$ lpass login --trust {email}")
    try:
        p = subprocess.run([lpass, "login", "--trust", email],
                           input=stdin, capture_output=True, text=True, timeout=120)
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}
    if p.returncode == 0:
        return {"ok": True}
    err = (p.stderr or p.stdout or "").strip()
    low = err.lower()
    # Heuristics: lpass asks for a code when MFA is on.
    if not otp and ("multifactor" in low or "out-of-band" in low or
                    "code" in low or "otp" in low or "google authenticator" in low):
        return {"ok": False, "mfa_required": True}
    if "invalid" in low and "password" in low:
        return {"ok": False, "error": "Incorrect email or master password."}
    return {"ok": False, "error": err[:240] or "lpass login failed."}


def lastpass_list_entries(on_log=None):
    """`lpass ls` → {entries: [...]}. Best-effort; empty list on failure."""
    lpass = find_lpass()
    if not lpass:
        return {"entries": [], "error": "LastPass CLI not found."}
    try:
        p = subprocess.run([lpass, "ls", "--format", "%/as%/ag%an"],
                           capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            # Fall back to the default ls format.
            p = subprocess.run([lpass, "ls"], capture_output=True,
                               text=True, timeout=30)
        names = []
        for line in (p.stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            # Default `lpass ls` is "Folder/Name [id: ...]"; strip the id tail.
            name = line.split(" [id:")[0].strip()
            if name:
                names.append(name)
        # De-dup, keep order.
        seen, out = set(), []
        for n in names:
            if n not in seen:
                seen.add(n)
                out.append(n)
        return {"entries": out}
    except Exception as e:
        return {"entries": [], "error": str(e)[:150]}


def _lpass_field(lpass, entry, field):
    """Read one field from a secure note (key=value notes or a custom field)."""
    try:
        p = subprocess.run([lpass, "show", "--field", field, entry],
                           capture_output=True, text=True, timeout=30)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except Exception:
        pass
    try:
        p = subprocess.run([lpass, "show", "--notes", entry],
                           capture_output=True, text=True, timeout=30)
        if p.returncode == 0:
            for line in p.stdout.splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    if k.strip() == field:
                        return v.strip()
    except Exception:
        pass
    return ""


def lastpass_validate_entry(entry, api_key_field, app_key_field):
    """Confirm the chosen entry actually yields both keys. {ok, error?}."""
    lpass = find_lpass()
    if not lpass:
        return {"ok": False, "error": "LastPass CLI not found."}
    if not entry:
        return {"ok": False, "error": "Pick an entry."}
    api = _lpass_field(lpass, entry, api_key_field or "datadogAPIKey")
    app = _lpass_field(lpass, entry, app_key_field or "datadogAPPKey")
    missing = [f for f, v in ((api_key_field or "datadogAPIKey", api),
                              (app_key_field or "datadogAPPKey", app)) if not v]
    if missing:
        return {"ok": False,
                "error": f"Couldn't read field(s) from “{entry}”: "
                         + ", ".join(missing)}
    return {"ok": True}


# --------------------------------------------------------------------------
# Install steps
# --------------------------------------------------------------------------
def app_source():
    """Locate datadog_assistant.py (frozen bundle, dev tree, or PyInstaller)."""
    here = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    for cand in (
        os.path.join(here, "datadog_assistant.py"),
        os.path.join(here, "..", "datadog_assistant.py"),
        os.path.join(here, "..", "Resources", "datadog_assistant.py"),
    ):
        if os.path.exists(cand):
            return os.path.abspath(cand)
    return None


def bundle_executable():
    """The .app executable to relaunch at login when we're a frozen bundle.

    py2app sets sys.executable to .../Contents/MacOS/<exe>, which boots the app
    again — straight into run mode (config exists), so notifications get the
    bundle identity."""
    return sys.executable if FROZEN else None


def build_config(c):
    """Normalize the GUI/CLI config dict into config.json contents.
    Secrets (keys, master password) are deliberately NOT included here."""
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            cfg = json.load(open(CONFIG_PATH))
        except Exception:
            cfg = {}
    cfg["site"] = c.get("site") or "datadoghq.com"
    cfg["app_subdomain"] = c.get("app_subdomain") or "app"
    cfg["tag_filter"] = c.get("tag_filter", "") or ""
    auth = c.get("auth", "keys")
    if auth == "oauth":
        cfg["auth"] = "oauth"
        cfg["oauth_client_id"] = c.get("oauth_client_id", "")
        cfg.pop("use_keychain", None)
    elif auth == "lastpass":
        lp = c.get("lastpass", {}) or {}
        cfg["auth"] = "lastpass"
        cfg["lastpass"] = {
            "entry": lp.get("entry", ""),
            "api_key_field": lp.get("api_key_field") or "datadogAPIKey",
            "app_key_field": lp.get("app_key_field") or "datadogAPPKey",
        }
        for k_src, k_dst in (("jira_client_id_field", "jira_client_id_field"),
                             ("jira_client_secret_field", "jira_client_secret_field")):
            if lp.get(k_src):
                cfg["lastpass"][k_dst] = lp[k_src]
        cfg.pop("use_keychain", None)
    else:
        cfg["auth"] = "keys"
        cfg["use_keychain"] = True
    return cfg


def _plist_dict(c):
    """The LaunchAgent definition (frozen → run the .app; script → venv python)."""
    if FROZEN and bundle_executable():
        program = [bundle_executable()]
    else:
        program = [os.path.join(APP_DIR, "venv", "bin", "python3"),
                   os.path.join(APP_DIR, "datadog_assistant.py")]
    env = {}
    if c.get("auth") == "lastpass":
        lp = c.get("lastpass", {}) or {}
        # 0 = never time out (within a session). LaunchAgents don't source the
        # shell rc, so this env is how the app's lpass gets the timeout at all.
        env["LPASS_AGENT_TIMEOUT"] = "0" if lp.get("never_expire", True) else \
            str(lp.get("agent_timeout", "3600"))
    d = {
        "Label": LABEL,
        "ProgramArguments": program,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Interactive",
        "StandardErrorPath": os.path.join(APP_DIR, "stderr.log"),
        "StandardOutPath": os.path.join(APP_DIR, "stdout.log"),
    }
    if env:
        d["EnvironmentVariables"] = env
    return d


def plist_xml(c):
    """LaunchAgent plist as XML text (also used by tests, no file I/O)."""
    return plistlib.dumps(_plist_dict(c)).decode()


def install(config, on_progress=None, on_log=None, dry_run=None):
    """Run the full install. Calls on_progress(frac, message) and on_log(line).
    Returns {ok, error?}. Idempotent / safe to re-run."""
    prog = on_progress or (lambda *_: None)
    log = on_log or (lambda *_: None)
    dry = _dry_run(dry_run)

    def sh(args, **kw):
        log("$ " + " ".join(args))
        if dry:
            return
        p = subprocess.run(args, capture_output=True, text=True, **kw)
        if p.stdout.strip():
            log(p.stdout.strip())
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip() or f"command failed: {args[0]}")

    try:
        prog(0.05, "Creating folders…")
        for d in (APP_DIR, CONFIG_DIR, os.path.dirname(PLIST_PATH)):
            os.makedirs(d, exist_ok=True)

        # Script mode needs the source + a venv; a frozen bundle ships its own.
        if not FROZEN:
            src = app_source()
            if not src:
                raise RuntimeError("Couldn't find datadog_assistant.py to install.")
            prog(0.20, "Copying the app…")
            if not dry:
                shutil.copy2(src, os.path.join(APP_DIR, "datadog_assistant.py"))
            venv = os.path.join(APP_DIR, "venv")
            py = find_python3()
            if not py:
                raise RuntimeError(
                    "python3 isn't installed. Open Terminal, run "
                    "'xcode-select --install', then try again.")
            if not os.path.exists(venv):
                prog(0.35, "Creating a Python environment…")
                sh([py, "-m", "venv", venv])
            prog(0.55, "Installing dependencies (rumps)…")
            pip = os.path.join(venv, "bin", "pip")
            sh([pip, "install", "--quiet", "--upgrade", "pip"])
            sh([pip, "install", "--quiet", "rumps>=0.4.0,<0.5"])

        prog(0.70, "Writing your settings…")
        cfg = build_config(config)
        # config.json is the testable contract — write it even in dry-run.
        with open(CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
        try:
            os.chmod(CONFIG_PATH, 0o600)  # owner-only on principle
        except OSError:
            pass

        if config.get("auth") == "keys":
            prog(0.82, "Storing your keys in the Keychain…")
            user = os.environ.get("USER", "user")
            for svc, val in ((API_KEY_SERVICE, config.get("api_key", "")),
                             (APP_KEY_SERVICE, config.get("app_key", ""))):
                if val:
                    sh(["security", "add-generic-password", "-U",
                        "-s", svc, "-a", user, "-w", val])

        prog(0.92, "Installing the login item…")
        if not dry:
            with open(PLIST_PATH, "wb") as f:
                f.write(plistlib.dumps(_plist_dict(config)))
            subprocess.run(["launchctl", "unload", PLIST_PATH],
                           capture_output=True)
            sh(["launchctl", "load", PLIST_PATH])

        prog(1.0, "Done")
        return {"ok": True}
    except Exception as e:
        log(f"ERROR: {e}")
        return {"ok": False, "error": str(e)}


def launch():
    """Start the app now (post-install, without waiting for the next login)."""
    if FROZEN and bundle_executable():
        subprocess.Popen([bundle_executable()])
    else:
        subprocess.run(["launchctl", "start", LABEL], capture_output=True)


# --------------------------------------------------------------------------
# Headless entry (CI / agents) — env-driven, mirrors install.sh's contract
# --------------------------------------------------------------------------
def _headless_main():
    cfg = {
        "site": os.environ.get("DD_SITE", "datadoghq.com"),
        "app_subdomain": os.environ.get("DD_APP_SUBDOMAIN", "app"),
        "tag_filter": os.environ.get("DD_TAG_FILTER", ""),
        "auth": os.environ.get("DD_AUTH", "keys"),
        "api_key": os.environ.get("DD_API_KEY", ""),
        "app_key": os.environ.get("DD_APP_KEY", ""),
        "oauth_client_id": os.environ.get("DD_OAUTH_CLIENT_ID", ""),
    }
    if cfg["auth"] == "lastpass":
        cfg["lastpass"] = {
            "entry": os.environ.get("DD_LASTPASS_ENTRY", ""),
            "api_key_field": os.environ.get("DD_LASTPASS_API_FIELD", "datadogAPIKey"),
            "app_key_field": os.environ.get("DD_LASTPASS_APP_FIELD", "datadogAPPKey"),
            "never_expire": os.environ.get("DD_LPASS_NEVER_EXPIRE", "1") == "1",
        }
    res = install(cfg, on_progress=lambda f, m: print(f"[{int(f*100):3d}%] {m}"),
                  on_log=lambda l: print("   " + l))
    print(json.dumps(res))
    sys.exit(0 if res.get("ok") else 1)


if __name__ == "__main__":
    _headless_main()
