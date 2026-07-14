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

There are no long-term support branches. Fixes land on `main` and ship in the
next tagged release; please verify a report against the latest `main` before
filing. The archived Python app in `legacy/python-app/` is out of support —
reports against it are welcome for awareness but won't get fixes.

## Handling of secrets (how the app is designed)

- Credentials (Datadog access token or API/App keys, GitHub and Jira tokens)
  are stored **encrypted on-device** by `SecretStore`: AES-GCM in an
  owner-only (0600) file inside an owner-only (0700) directory, excluded from
  iCloud/Time Machine, with the encryption key wrapped by the **Secure
  Enclave** where the hardware supports it (random-key fallback otherwise).
  The macOS login Keychain is deliberately not used (an ad-hoc-signed app
  triggers password prompts on every access).
- Credentials supplied via environment variables or a password-manager
  command are used **in memory only** — never persisted.
- LastPass-vault mode fetches credentials at runtime via the `lpass` CLI;
  vault-sourced secrets (including the Jira client secret) are **not**
  persisted on-device.
- The app talks to Datadog/GitHub/Jira over HTTPS with default certificate
  verification. It never disables TLS verification. The Jira OAuth callback
  listener binds to loopback only.

If you believe any of the above does not hold, that's a security issue — please
report it via the process above.
