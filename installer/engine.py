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
import re
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


_FALLBACK_VERSION = "1.1.0"


def app_version():
    """Single-sourced from datadog_assistant.py's __version__, so the
    onboarding UI, the bundle plist (setup.py) and bug reports all agree
    instead of each hardcoding its own number."""
    src = app_source()
    if src:
        try:
            with open(src) as f:
                m = re.search(r'^__version__\s*=\s*"([^"]+)"', f.read(), re.M)
            if m:
                return m.group(1)
        except OSError:
            pass
    return _FALLBACK_VERSION


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
        "app_version": app_version(),
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


def _redact(text, *secrets):
    for s in secrets:
        if s:
            text = text.replace(s, "•••")
    return text


def _lp_log(msg):
    """Append a line to ~/.datadog-assistant/lastpass.log so LastPass login is
    diagnosable even from the bundle (where stderr isn't a terminal). Created
    0600 — it holds login transcripts (email, prompt flow), which mustn't be
    readable by other local users."""
    try:
        d = os.path.expanduser("~/.datadog-assistant")
        os.makedirs(d, exist_ok=True)
        fd = os.open(os.path.join(d, "lastpass.log"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(msg.rstrip("\n") + "\n")
    except Exception:
        pass


# Prompt fragments lpass prints; used to know which input it's waiting for.
_PW_PROMPTS = ("master password", "password")
_OTP_PROMPTS = ("code", "factor", "passcode", "otp", "authenticat", "google",
                "yubikey", "out-of-band")


def lastpass_login(email, password, otp="", never_expire=True, on_log=None):
    """Log in to LastPass by driving `lpass login` through a pseudo-terminal,
    answering the master-password prompt and (if the account has an
    authenticator) the code prompt. Returns:
      {ok: True}                              on success
      {ok: False, mfa_required: True}         password ok but a code is needed
      {ok: False, error, detail}              otherwise (detail = lpass output)

    A pty is used because lpass reads the password from the controlling
    terminal, not plain stdin — piping alone fails on MFA accounts. lpass's
    actual prompts/errors are logged (with secrets redacted) so failures are
    diagnosable."""
    log = on_log or (lambda *_: None)
    lpass = find_lpass()
    if not lpass:
        return {"ok": False, "error": "LastPass CLI not found."}
    if not email or not password:
        return {"ok": False, "error": "Email and master password are required."}

    env = dict(os.environ)
    env["LPASS_DISABLE_PINENTRY"] = "1"
    # 0 = never time out (within a session) so the menu-bar app's session
    # holds. When the user opts OUT of "keep me signed in", fall back to 1h —
    # an empty string parses as 0 in lpass, which would silently mean
    # "never expire": the exact opposite of the user's choice.
    env["LPASS_AGENT_TIMEOUT"] = "0" if never_expire else (
        env.get("LPASS_AGENT_TIMEOUT") or "3600")

    log(f"$ lpass login --trust {email}")
    _lp_log(f"=== login attempt: lpass={lpass}, email={email}, "
            f"otp={'yes' if otp else 'no'} ===")
    transcript, saw_otp_prompt, how = _drive_lpass_login(
        lpass, email, password, otp, env)
    detail = _redact(transcript, password, otp).strip()

    # Surface what lpass actually said (redacted) — file, GUI log, and stderr.
    _lp_log(f"[{how}] saw_otp_prompt={saw_otp_prompt}\ntranscript:\n{detail}")
    for line in detail.splitlines():
        line = line.strip()
        if line:
            log("lpass: " + line)
            print("lpass: " + line, file=sys.stderr)

    # `lpass status` is the source of truth for whether we're in — but it
    # must show THIS account: a pre-existing session for a different account
    # would otherwise mask a failed login and the app would silently read
    # the wrong vault.
    status_out = ""
    try:
        p = subprocess.run([lpass, "status"], capture_output=True,
                           text=True, timeout=10)
        status_out = (p.stdout or "").strip()
        logged = p.returncode == 0 and "Logged in" in status_out
    except Exception:
        logged = False
    if logged and email.lower() in status_out.lower():
        result = {"ok": True}
    elif logged:
        result = {"ok": False,
                  "error": f"LastPass session belongs to a different account "
                           f"({status_out}). Run `lpass logout` in Terminal, "
                           f"then try again.",
                  "detail": detail[-400:]}
    else:
        low = detail.lower()
        if saw_otp_prompt and not otp:
            result = {"ok": False, "mfa_required": True, "detail": detail[-400:]}
        elif saw_otp_prompt and otp:
            result = {"ok": False,
                      "error": "LastPass rejected the authenticator code (or it "
                               "expired — try the current one).",
                      "detail": detail[-400:]}
        elif "password" in low and any(w in low for w in
                                       ("incorrect", "could not", "failed",
                                        "invalid")):
            result = {"ok": False,
                      "error": "LastPass rejected the master password.",
                      "detail": detail[-400:]}
        elif not detail:
            result = {"ok": False,
                      "error": "LastPass didn't respond (no prompt seen). See "
                               "~/.datadog-assistant/lastpass.log.",
                      "detail": ""}
        else:
            result = {"ok": False, "error": detail[-200:],
                      "detail": detail[-400:]}
    _lp_log(f"result: {result}")
    return result


def _drive_lpass_login(lpass, email, password, otp, env):
    """Run `lpass login` under a pty, feeding the password and (if asked) the
    code. Returns (transcript, saw_otp_prompt, how). Falls back to a plain pipe
    if a pty can't be allocated. Bounded by an overall deadline and an idle
    timeout so it can never hang the GUI."""
    try:
        import pty
        import select
        import signal
        import time
    except Exception:
        return _drive_lpass_login_pipe(lpass, email, password, otp, env)

    try:
        pid, fd = pty.fork()
    except Exception:
        return _drive_lpass_login_pipe(lpass, email, password, otp, env)

    if pid == 0:  # child → become lpass
        try:
            os.execvpe(lpass, [lpass, "login", "--trust", email], env)
        except Exception:
            os._exit(127)
        os._exit(127)

    transcript = ""
    buf = ""
    sent_pw = sent_otp = saw_otp = False
    start = time.time()
    deadline = start + 45          # hard cap
    last_activity = start
    try:
        while time.time() < deadline:
            try:
                rlist, _, _ = select.select([fd], [], [], 0.5)
            except (OSError, ValueError):
                break
            if not rlist:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    break
                if done:
                    pid = 0
                    break
                # No output and the child's still alive: if it's been idle a
                # while it's wedged (or waiting on a prompt we didn't match) —
                # bail rather than spin to the hard deadline.
                if time.time() - last_activity > 20:
                    transcript += "\n[timed out waiting for lpass]"
                    break
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            last_activity = time.time()
            chunk = data.decode("utf-8", "replace")
            transcript += chunk
            buf += chunk
            low = buf.lower()
            if not sent_pw and any(p in low for p in _PW_PROMPTS):
                os.write(fd, (password + "\n").encode())
                sent_pw = True
                buf = ""
                continue
            if sent_pw and not sent_otp and any(p in low for p in _OTP_PROMPTS):
                saw_otp = True
                if otp:
                    os.write(fd, (otp + "\n").encode())
                    sent_otp = True
                    buf = ""
                    continue
                break  # need a code we don't have → stop and report mfa_required
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass
            # Bounded reap: a wedged lpass that ignores SIGTERM must not
            # hang this (GUI-facing) thread in a blocking waitpid forever —
            # poll briefly, then SIGKILL.
            reaped = False
            for _ in range(20):                       # ~2s total
                try:
                    done, _st = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    reaped = True
                    break
                if done:
                    reaped = True
                    break
                time.sleep(0.1)
            if not reaped:
                try:
                    os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass
                try:
                    os.waitpid(pid, 0)
                except Exception:
                    pass
        try:
            os.close(fd)
        except OSError:
            pass
    return transcript, saw_otp, "pty"


def _drive_lpass_login_pipe(lpass, email, password, otp, env):
    """Fallback when no pty is available: feed password (+otp) via stdin."""
    stdin = (password + "\n" + otp + "\n") if otp else password + "\n"
    try:
        p = subprocess.run([lpass, "login", "--trust", email], input=stdin,
                           capture_output=True, text=True, timeout=45, env=env)
        out = (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return (str(e), False, "pipe")
    low = out.lower()
    saw_otp = any(k in low for k in _OTP_PROMPTS)
    return (out, saw_otp, "pipe")


def lastpass_list_entries(on_log=None):
    """`lpass ls` → {entries: [...]}. Best-effort; empty list on failure.
    The raw result is logged to lastpass.log so an empty list is diagnosable."""
    lpass = find_lpass()
    if not lpass:
        return {"entries": [], "error": "LastPass CLI not found."}
    try:
        # Plain `lpass ls`. Lines look like "Group/Name [id: 1234]" on most
        # builds, but some print just "Group/Name" with no id — so DON'T filter
        # on "[id:" (that silently dropped every entry). Just strip the id tail
        # if present and keep every non-empty line.
        p = subprocess.run([lpass, "ls"],
                           capture_output=True, text=True, timeout=45)
        out_text, err_text, rc = p.stdout or "", p.stderr or "", p.returncode
    except Exception as e:
        _lp_log(f"ls error: {e}")
        return {"entries": [], "error": str(e)[:150]}

    seen, entries = set(), []
    for line in out_text.splitlines():
        line = line.strip()
        if not line:
            continue
        name = line.split(" [id:")[0].strip()
        if name and name not in seen:
            seen.add(name)
            entries.append(name)
    _lp_log(f"ls: rc={rc}, {len(entries)} entries, {len(out_text.splitlines())} "
            f"raw lines; stderr={err_text.strip()[:160]}")
    return {"entries": entries}


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
    """The .app's launcher (Contents/MacOS/<CFBundleExecutable>) to run at login.

    NOT sys.executable: under py2app that's a bare Python interpreter inside the
    bundle, so launchd would run it as an empty REPL that reads EOF and exits 0
    (no app, no icon). NSBundle gives the real launcher that boots the app."""
    if not FROZEN:
        return None
    try:
        from Foundation import NSBundle
        p = NSBundle.mainBundle().executablePath()
        if p:
            return str(p)
    except Exception:
        pass
    # Fallback: derive Contents/MacOS/<AppName> from the bundle layout.
    macos = os.path.dirname(sys.executable)              # …/Contents/MacOS
    appdir = os.path.dirname(os.path.dirname(macos))     # …/<Name>.app
    name = os.path.basename(appdir)
    if name.endswith(".app"):
        name = name[:-4]
    cand = os.path.join(macos, name)
    return cand if os.path.exists(cand) else sys.executable


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
    # Force run mode via env, NOT a CLI flag: the py2app app stub exits 2 when
    # launchd hands it an unrecognized argument like --run.
    env = {"DD_NO_ONBOARD": "1"}
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


def _keychain_add(service, account, secret, log, dry):
    """Store a secret in the login Keychain WITHOUT exposing it: the command is
    fed to `security -i` on stdin, so the secret never appears in argv (visible
    to any local process via ps) nor in the install log (which echoes every
    command). The log line shows a redacted placeholder instead."""
    log(f"$ security add-generic-password -U -s {service} -a {account} -w •••")
    if dry:
        return
    quoted = '"' + secret.replace("\\", "\\\\").replace('"', '\\"') + '"'
    subprocess.run(
        ["security", "-i"],
        input=(f'add-generic-password -U -s "{service}" '
               f'-a "{account}" -w {quoted}\n'),
        capture_output=True, text=True)
    # `security -i` exit codes are unreliable across macOS versions — verify
    # the item actually landed instead of trusting the return code.
    chk = subprocess.run(["security", "find-generic-password", "-s", service],
                         capture_output=True, text=True)
    if chk.returncode != 0:
        raise RuntimeError(f"storing {service} in the Keychain failed — "
                           "is the login keychain locked?")


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

    # config.json doubles as the "onboarding is done" marker (_should_onboard
    # in datadog_assistant.py). If THIS run creates it and a later step fails,
    # remove it again — otherwise a half-install permanently skips onboarding
    # with no credentials and no login item.
    config_existed = os.path.exists(CONFIG_PATH)
    wrote_config = False
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
        # Created 0600 (it can name vault entries etc.), not chmod'd after —
        # no window of default-umask readability.
        fd = os.open(CONFIG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(cfg, f, indent=2)
        wrote_config = True
        try:
            os.chmod(CONFIG_PATH, 0o600)  # pre-existing file: tighten anyway
        except OSError:
            pass

        if config.get("auth") == "keys":
            prog(0.82, "Storing your keys in the Keychain…")
            user = os.environ.get("USER", "user")
            for svc, val in ((API_KEY_SERVICE, config.get("api_key", "")),
                             (APP_KEY_SERVICE, config.get("app_key", ""))):
                if val:
                    _keychain_add(svc, user, val, log, dry)

        prog(0.92, "Installing the login item…")
        if not dry:
            with open(PLIST_PATH, "wb") as f:
                f.write(plistlib.dumps(_plist_dict(config)))
            _bootstrap_launchagent(log)

        prog(1.0, "Done")
        return {"ok": True}
    except Exception as e:
        log(f"ERROR: {e}")
        if wrote_config and not config_existed:
            try:
                os.remove(CONFIG_PATH)
                log("rolled back config.json so setup reopens next launch")
            except OSError:
                pass
        return {"ok": False, "error": str(e)}


def _gui_domain():
    return f"gui/{os.getuid()}"


def _bootstrap_launchagent(log=None):
    """(Re)load the LaunchAgent into the GUI session domain and start it.

    The legacy `launchctl load` works from a terminal but NOT when invoked from
    inside a GUI app (as onboarding is) — the agent loads into the wrong domain
    and its menu-bar status item never appears. `bootstrap gui/$UID` targets the
    GUI session explicitly. Falls back to load/start on older macOS."""
    log = log or (lambda *_: None)
    domain = _gui_domain()
    # Clear any prior registration (ignore errors — it may not be loaded).
    subprocess.run(["launchctl", "bootout", domain, PLIST_PATH],
                   capture_output=True)
    r = subprocess.run(["launchctl", "bootstrap", domain, PLIST_PATH],
                       capture_output=True, text=True)
    if r.returncode != 0:
        log(f"bootstrap failed ({r.stderr.strip()[:120]}); using legacy load")
        subprocess.run(["launchctl", "unload", PLIST_PATH], capture_output=True)
        subprocess.run(["launchctl", "load", "-w", PLIST_PATH],
                       capture_output=True)
    _kickstart()


def _kickstart():
    """Ensure the agent is running now (idempotent — no-op if already up)."""
    r = subprocess.run(["launchctl", "kickstart", f"{_gui_domain()}/{LABEL}"],
                       capture_output=True)
    if r.returncode != 0:
        subprocess.run(["launchctl", "start", LABEL], capture_output=True)


def launch():
    """Ensure the menu-bar app is running now (post-install). install() already
    bootstrapped + started the agent; this is an idempotent nudge, not a second
    raw instance (which would race the single-instance lock)."""
    _kickstart()


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
