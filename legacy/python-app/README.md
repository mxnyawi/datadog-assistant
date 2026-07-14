# Legacy Python app (archived)

> **⚠️ This implementation is retired.** The actively-developed Datadog
> Assistant is the native Swift app in [`swift/`](../../swift/) — install it
> from the [latest release](https://github.com/mxnyawi/datadog-assistant/releases/latest)
> or with Homebrew (see the [root README](../../README.md)).

This directory preserves the original Python/[`rumps`](https://github.com/jaredks/rumps)
menu-bar app for historical reference. It still works, but it receives no new
features or fixes, is not part of CI, and is not an install option in the docs.

- Full documentation: [`docs/legacy-python-app.md`](../../docs/legacy-python-app.md)
- Last state as a root-level product: the `python-final` git tag
  (the last Python-era release was
  [v0.3.0](https://github.com/mxnyawi/datadog-assistant/releases/tag/v0.3.0))

## Contents

| Path | What it was |
|---|---|
| `datadog_assistant.py` | The whole app (Python 3 + rumps) |
| `install.sh` | venv + Keychain + LaunchAgent installer |
| `installer/` | The unified self-onboarding .app installer + release tooling |
| `onboarding_app.py`, `qa_gui.py` | GUI onboarding / QA harness |
| `test_smoke.py`, `test_onboarding.py` | Test suite (run with `python3 test_smoke.py`) |
| `config.example.json` | Example config for `~/.config/datadog-assistant/config.json` |

If you were running the Python app: your credentials live in the macOS login
Keychain (`datadog-assistant-api-key` / `datadog-assistant-app-key`) and your
config in `~/.config/datadog-assistant/config.json`. The Swift app does not
migrate them automatically — connect it with a Datadog access token (or the
same keys / LastPass entry) from its in-app prompt, then uninstall this one:

```bash
launchctl unload ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
rm -rf ~/.datadog-assistant ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
```
