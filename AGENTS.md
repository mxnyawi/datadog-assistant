# AGENTS.md — guide for coding agents

Instructions for AI coding agents (Claude Code, Cursor, Copilot, etc.) setting
up, running, or contributing to **Datadog Assistant**. Humans: see
[`README.md`](README.md).

## What this is

A macOS **menu bar** app (`rumps`) that surfaces Datadog monitors and fires
notifications. It is GUI software — it must run on a real macOS desktop session
to show its 🐶 icon. There is no headless/server mode.

## Prerequisites (check before installing)

| Requirement | Check | Notes |
|---|---|---|
| macOS | `uname` → `Darwin` | Menu bar app; will not work on Linux. |
| **Python 3.10+** | `python3 --version` | **Do not use system Python 3.9.** On 3.9 `pip` resolves a *yanked* `pyobjc-core` and compiles it from source (slow, needs Xcode CLT). 3.10+ installs a prebuilt wheel in seconds. `brew install python@3.12` if needed. |
| Datadog API + App keys | — | App key needs scopes `monitors_read`, `monitors_write`, `monitors_downtime` (add `dashboards_read`, `incident_read`, `metrics_read`, `events_read` for full features). |

If `python3` is older than 3.10, run the installer with a newer interpreter
first on `PATH`, e.g.:

```bash
mkdir -p .shim && ln -sf "$(brew --prefix)/bin/python3.12" .shim/python3
PATH="$PWD/.shim:$PATH" ./install.sh
```

## Unattended install (the agent path)

`install.sh` runs non-interactively when `DD_NONINTERACTIVE=1` **or** when stdin
isn't a TTY (the normal case for an agent). Provide every setting as an
environment variable — the script never prompts:

```bash
DD_NONINTERACTIVE=1 \
DD_SITE=datadoghq.eu \
DD_APP_SUBDOMAIN=yourorg \
DD_TAG_FILTER="team:payments env:prod" \
DD_AUTH=keys \
DD_API_KEY="$DD_API_KEY" DD_APP_KEY="$DD_APP_KEY" \
./install.sh
```

| Variable | Maps to config | Default | Notes |
|---|---|---|---|
| `DD_NONINTERACTIVE` | — | _(interactive)_ | `1` to skip all prompts; auto-on when no TTY. |
| `DD_SITE` | `site` | `datadoghq.com` | e.g. `datadoghq.eu`, `us3.datadoghq.com`, `ddog-gov.com`. **Wrong site = 403.** |
| `DD_APP_SUBDOMAIN` | `app_subdomain` | `app` | Set to your org slug if you browse `yourorg.datadoghq.eu`. |
| `DD_TAG_FILTER` | `tag_filter` | _(all monitors)_ | Space-separated, e.g. `team:payments env:prod`. |
| `DD_AUTH` | `auth` | `keys` | `keys`, `oauth`, or `lastpass`. Anything else exits 1. |
| `DD_API_KEY` / `DD_APP_KEY` | _(Keychain)_ | — | Stored in the macOS Keychain, **never** written to `config.json`. |
| `DD_OAUTH_CLIENT_ID` | `oauth_client_id` | — | For `DD_AUTH=oauth`. OAuth still needs an interactive browser login afterwards, so prefer `keys` for automation. |
| `DD_LASTPASS_ENTRY` | `lastpass.entry` | — | **Required** for `DD_AUTH=lastpass` in unattended mode (errors without it). Optional field overrides: `DD_LASTPASS_API_FIELD`, `DD_LASTPASS_APP_FIELD`, `DD_LASTPASS_JIRA_CID_FIELD`, `DD_LASTPASS_JIRA_SEC_FIELD`; agent timeout via `DD_LPASS_AGENT_TIMEOUT`. Needs `lpass` installed + logged in. |

The installer copies the app to `~/.datadog-assistant`, creates a venv, installs
`rumps`, writes `~/.config/datadog-assistant/config.json`, and loads a
LaunchAgent (`~/Library/LaunchAgents/com.nour.datadog-assistant.plist`).

## Credential handling (rules for agents)

- **Never** put real keys in `config.json`, in commits, or in your transcript.
- Read keys from the environment / a secret store and pass them through; or have
  the human store them and just point config at the Keychain:
  ```bash
  security add-generic-password -U -s datadog-assistant-api-key -a "$USER" -w 'API_KEY'
  security add-generic-password -U -s datadog-assistant-app-key  -a "$USER" -w 'APP_KEY'
  ```
  then ensure `config.json` has `"auth": "keys"` and `"use_keychain": true`.
- The app also supports `*_cmd` config keys to shell out to a password manager
  (1Password, LastPass, Vault…) — see the README "Company setups" section.

## Verify the install (read-only, no GUI clicks needed)

```bash
# Process loaded?
launchctl list | grep datadog-assistant
# App + deps present?
~/.datadog-assistant/venv/bin/python3 -c "import rumps, objc; print('ok')"
# Any startup errors?
tail -n 20 ~/.datadog-assistant/stderr.log
```

To confirm credentials/region without using the menu, probe the Datadog API
read-only with the stored keys (adjust `site`):

```bash
API=$(security find-generic-password -s datadog-assistant-api-key -w)
APP=$(security find-generic-password -s datadog-assistant-app-key -w)
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "DD-API-KEY: $API" -H "DD-APPLICATION-KEY: $APP" \
  "https://api.datadoghq.eu/api/v1/validate"   # 200 = good, 403 = wrong site/scopes
```

## Restart / uninstall

```bash
# Restart after a config or key change:
launchctl kickstart -k "gui/$(id -u)/com.nour.datadog-assistant"

# Uninstall:
launchctl unload ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
rm -rf ~/.datadog-assistant ~/Library/LaunchAgents/com.nour.datadog-assistant.plist
```

## Contributing (for agents writing code)

- Run `python3 test_smoke.py` before proposing changes — most logic is testable
  on Linux without a Mac.
- **Stdlib + `rumps` only.** No new runtime dependencies; API clients use
  `urllib`. Keep changes small and focused.
- Update `README.md` and `config.example.json` when you add or change a config
  key or user-facing behavior.
- State in the PR what you actually tested, and whether it was on real macOS
  (notifications, menu bar, and `osascript` paths can only be verified there).
- See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full checklist.
