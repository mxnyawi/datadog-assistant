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

print("ENGINE TESTS PASSED ✅")
