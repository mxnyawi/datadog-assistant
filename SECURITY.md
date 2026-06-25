# Security Policy

Datadog Assistant handles credentials — Datadog API/App keys, Jira OAuth tokens,
and (optionally) a shared LastPass entry — so security reports are taken
seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/mxnyawi/datadog-assistant/security/advisories/new)**
(repo → **Security** tab → **Report a vulnerability**).

If you can't use that, email the maintainer listed on the
[GitHub profile](https://github.com/mxnyawi).

Please include:

- what you found and where (file / function / install step),
- how to reproduce it, and
- the impact you think it has.

You'll get an acknowledgement as soon as possible. Please give a reasonable
window to ship a fix before any public disclosure.

## Supported versions

This is a single-file app with no long-term support branches. Fixes land on
`main` and ship in the next tagged release; please verify a report against the
latest `main` before filing.

## Handling of secrets (how the app is designed)

- Credentials are stored in the **macOS Keychain** by default. When the Keychain
  is unavailable, `config.json` / `state.json` are written **owner-only (0600)**
  in an owner-only directory (0700).
- API/App keys supplied via environment variables are written **straight to the
  Keychain**, never to `config.json`.
- LastPass-sourced Jira secrets are kept **in memory only** and are stripped
  before any config is persisted.
- The app talks to Datadog/Jira over HTTPS with default certificate
  verification. It never disables TLS verification.

If you believe any of the above does not hold, that's a security issue — please
report it via the process above.
