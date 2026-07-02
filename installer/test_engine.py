"""Unit tests for the install engine. Runs on Linux (DD_DRY_RUN skips every
system mutation), so the GUI/CLI install contract is assertable without a Mac.

    DD_DRY_RUN=1 python3 installer/test_engine.py
"""
import json
import os
import sys
import tempfile

# Isolate HOME *before* importing engine (its paths are computed at import).
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp
os.environ["DD_DRY_RUN"] = "1"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine  # noqa: E402

# ---- build_config: keys mode → keychain, no secrets in config ----
cfg = engine.build_config({"site": "datadoghq.eu", "app_subdomain": "acme",
                           "tag_filter": "team:pay", "auth": "keys",
                           "api_key": "SECRET", "app_key": "SECRET2"})
assert cfg["site"] == "datadoghq.eu", cfg
assert cfg["app_subdomain"] == "acme", cfg
assert cfg["tag_filter"] == "team:pay", cfg
assert cfg["auth"] == "keys" and cfg["use_keychain"] is True, cfg
assert "SECRET" not in json.dumps(cfg), "API/App keys must NEVER land in config.json"

# ---- build_config: oauth ----
cfg = engine.build_config({"auth": "oauth", "oauth_client_id": "cid123"})
assert cfg["auth"] == "oauth" and cfg["oauth_client_id"] == "cid123", cfg
assert "use_keychain" not in cfg, cfg

# ---- build_config: lastpass with field defaults ----
cfg = engine.build_config({"auth": "lastpass",
                           "lastpass": {"entry": "Shared/dd"}})
assert cfg["auth"] == "lastpass", cfg
assert cfg["lastpass"]["entry"] == "Shared/dd", cfg
assert cfg["lastpass"]["api_key_field"] == "datadogAPIKey", cfg
assert cfg["lastpass"]["app_key_field"] == "datadogAPPKey", cfg

# ---- plist: lastpass never-expire injects LPASS_AGENT_TIMEOUT=0 ----
xml = engine.plist_xml({"auth": "lastpass", "lastpass": {"never_expire": True}})
assert "LPASS_AGENT_TIMEOUT" in xml and "<string>0</string>" in xml, xml
assert engine.LABEL in xml, xml
# keys mode has no LPASS env
assert "LPASS_AGENT_TIMEOUT" not in engine.plist_xml({"auth": "keys"})

# ---- plist forces run mode via env (NOT a --run arg the app stub rejects) ----
for mode in ("keys", "oauth", "lastpass"):
    px = engine.plist_xml({"auth": mode})
    assert "DD_NO_ONBOARD" in px, px
    assert "--run" not in px, px

# ---- plist program target: script mode runs the venv python + the script ----
# (FROZEN is False under the test interpreter)
assert engine.FROZEN is False
xml = engine.plist_xml({"auth": "keys"})
assert "venv/bin/python3" in xml and "datadog_assistant.py" in xml, xml

# ---- validate_datadog_keys: empty keys fail fast without a network call ----
r = engine.validate_datadog_keys("datadoghq.com", "", "")
assert r["ok"] is False and "required" in r["error"].lower(), r

# ---- install(): dry-run writes a correct config.json and reports ok ----
steps = []
res = engine.install(
    {"site": "us3.datadoghq.com", "auth": "keys",
     "api_key": "k", "app_key": "p", "tag_filter": "env:prod"},
    on_progress=lambda f, m: steps.append((f, m)),
    on_log=lambda l: None)
assert res["ok"] is True, res
assert steps and steps[-1][0] == 1.0, steps
written = json.load(open(engine.CONFIG_PATH))
assert written["site"] == "us3.datadoghq.com", written
assert written["auth"] == "keys" and written["use_keychain"] is True, written
assert written["tag_filter"] == "env:prod", written

# ---- lastpass helpers degrade gracefully when lpass is absent ----
if not engine.find_lpass():
    assert engine.lpass_logged_in() is False
    assert engine.lastpass_login("a@b.com", "pw")["ok"] is False
    assert engine.lastpass_list_entries()["entries"] == []
    assert engine.lastpass_validate_entry("x", "a", "b")["ok"] is False

# ---- install(): key values are NEVER echoed into the install log ----
# (the log renders verbatim in the GUI pane and goes to stdout in headless
# mode — a key here is a permanent credential leak)
lines = []
res = engine.install(
    {"site": "datadoghq.com", "auth": "keys",
     "api_key": "SUPERSECRETKEY123", "app_key": "OTHERSECRET456"},
    on_log=lines.append)
assert res["ok"] is True, res
blob = "\n".join(lines)
assert "SUPERSECRETKEY123" not in blob and "OTHERSECRET456" not in blob, blob
assert "•••" in blob, blob            # the redacted keychain line is still shown

# ---- install(): failure AFTER config.json was created rolls it back ----
# config.json is the onboarding gate — leaving it behind on a failed install
# permanently skips setup with no credentials installed.
os.remove(engine.CONFIG_PATH)


def _boom(*a, **k):
    raise RuntimeError("keychain locked")


_orig_kc = engine._keychain_add
engine._keychain_add = _boom
res = engine.install({"auth": "keys", "api_key": "k", "app_key": "p"})
engine._keychain_add = _orig_kc
assert res["ok"] is False, res
assert not os.path.exists(engine.CONFIG_PATH), \
    "failed install must remove the config.json it created"

# ...but a PRE-EXISTING config survives a failed re-install
res = engine.install({"auth": "keys", "api_key": "k", "app_key": "p"})
assert res["ok"] is True and os.path.exists(engine.CONFIG_PATH), res
engine._keychain_add = _boom
res = engine.install({"auth": "keys", "api_key": "k", "app_key": "p"})
engine._keychain_add = _orig_kc
assert res["ok"] is False, res
assert os.path.exists(engine.CONFIG_PATH), \
    "re-install failure must not delete the user's existing config"

# ---- version is single-sourced from datadog_assistant.py ----
import re  # noqa: E402
src = open(engine.app_source()).read()
want = re.search(r'^__version__\s*=\s*"([^"]+)"', src, re.M).group(1)
assert engine.app_version() == want, engine.app_version()
assert engine.detect_env()["app_version"] == want

# ---- opting OUT of never-expire must not silently mean "never expire" ----
env_backup = os.environ.pop("LPASS_AGENT_TIMEOUT", None)
captured = {}


def _capture_drive(lpass, email, password, otp, env):
    captured["timeout"] = env.get("LPASS_AGENT_TIMEOUT")
    return ("", False, "stub")


_orig_drive = engine._drive_lpass_login
engine._drive_lpass_login = _capture_drive
_orig_find, engine.find_lpass = engine.find_lpass, lambda: "/bin/true"
_orig_status = engine.lpass_logged_in
engine.lpass_logged_in = lambda *_: False
engine.lastpass_login("a@b.com", "pw", never_expire=False)
assert captured["timeout"] == "3600", captured   # "" would parse as 0 = never
engine.lastpass_login("a@b.com", "pw", never_expire=True)
assert captured["timeout"] == "0", captured
engine._drive_lpass_login = _orig_drive
engine.find_lpass = _orig_find
engine.lpass_logged_in = _orig_status
if env_backup is not None:
    os.environ["LPASS_AGENT_TIMEOUT"] = env_backup

print("ENGINE TESTS PASSED ✅")
