"""Unit tests for the onboarding bridge (onboarding_app.Api). Runs on Linux:
pywebview is only imported inside run(), so the bridge + engine are exercisable
without a GUI. DD_DRY_RUN keeps install() from touching the system.

    DD_DRY_RUN=1 python3 test_onboarding.py
"""
import json
import os
import tempfile
import time

os.environ["HOME"] = tempfile.mkdtemp()
os.environ["DD_DRY_RUN"] = "1"

import onboarding_app  # noqa: E402
import engine  # noqa: E402  (put on sys.path by onboarding_app)

api = onboarding_app.Api()           # no window — _emit() is a safe no-op
api._window = None

# get_init surfaces sites + env for the first screen
init = api.get_init()
assert any(s["value"] == "datadoghq.com" for s in init["sites"]), init
assert "has_homebrew" in init["env"] and "has_lpass" in init["env"], init

# validate_datadog_keys delegates to the engine (empty keys fail fast)
r = api.validate_datadog_keys({"site": "datadoghq.com", "api_key": "", "app_key": ""})
assert r["ok"] is False, r

# lastpass methods degrade gracefully when lpass is absent
if not engine.find_lpass():
    assert api.lastpass_login({"email": "a@b.com", "password": "x"})["ok"] is False
    assert api.lastpass_list_entries()["entries"] == []
    assert api.lastpass_validate_entry({"entry": "e", "api_key_field": "a",
                                        "app_key_field": "b"})["ok"] is False

# open_external never raises
assert api.open_external({"url": "https://example.com"})["ok"] is True
assert api.open_external({})["ok"] is True

# begin_install runs the engine in a worker thread and writes config.json
assert api.begin_install({"site": "datadoghq.eu", "auth": "keys",
                          "api_key": "k", "app_key": "p"})["ok"] is True
for _ in range(50):                  # wait up to ~5s for the worker
    if os.path.exists(engine.CONFIG_PATH):
        break
    time.sleep(0.1)
cfg = json.load(open(engine.CONFIG_PATH))
assert cfg["site"] == "datadoghq.eu" and cfg["auth"] == "keys", cfg

# web assets resolve from the dev tree
assert onboarding_app.web_dir() is not None, "onboarding web/ not found"

# begin_install is single-flight: a second click while an install is running
# must be refused, not start a second worker racing the first on config.json
# and launchctl
import threading  # noqa: E402

gate = threading.Event()
done = threading.Event()
orig_install = engine.install


def slow_install(cfg, on_progress=None, on_log=None, dry_run=None):
    try:
        gate.wait(5)
        return orig_install(cfg, on_progress=on_progress, on_log=on_log,
                            dry_run=dry_run)
    finally:
        done.set()


engine.install = slow_install
api2 = onboarding_app.Api()
assert api2.begin_install({"auth": "keys"})["ok"] is True
r = api2.begin_install({"auth": "keys"})
assert r["ok"] is False and "progress" in r["error"].lower(), r
gate.set()
done.wait(5)
engine.install = orig_install

print("ONBOARDING BRIDGE TESTS PASSED ✅")
