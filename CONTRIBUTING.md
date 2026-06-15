# Contributing to Datadog Assistant 🐶

Thanks for taking the time to contribute! This is a small, friendly project and
all kinds of help are welcome — bug reports, feature ideas, docs fixes, and code.

> ⚠️ This is an **unofficial** personal tool, not affiliated with or endorsed by
> Datadog, Inc. or Atlassian. Please keep contributions in that spirit.

## Ways to help

- 🐛 **Found a bug?** Open an [issue](https://github.com/mxnyawi/datadog-assistant/issues)
  using the Bug Report template. Logs live at `~/.datadog-assistant/stderr.log`
  — redact your keys and any private monitor names before pasting.
- 💡 **Have an idea?** Open a Feature Request issue, or start a
  [Discussion](https://github.com/mxnyawi/datadog-assistant/discussions) if it's
  more of an open question. There's a roadmap section at the bottom of the README.
- 📖 **Docs/typos?** Small README or comment fixes are very welcome — just open a PR.
- 💻 **Code?** See the workflow below.

## Project shape

It's deliberately simple:

- **`datadog_assistant.py`** — the whole app. Python 3 + [`rumps`](https://github.com/jaredks/rumps)
  for the menu bar; the Datadog and Jira API clients are **stdlib-only**
  (`urllib`), no `requests`. Please keep it that way unless there's a strong
  reason — zero runtime deps beyond `rumps` is a feature.
- **`config.example.json`** — every config key with a sane default. If you add a
  config option, document it here and in the README.
- **`test_smoke.py`** — import/logic tests with `rumps` stubbed out, so they run
  on **Linux/CI without a Mac**.
- **`install.sh`** — venv + Keychain + LaunchAgent setup.
- **`docs/`** — the README screenshots and the `mockup.html` / `shoot.py` that
  generate them.

## Dev setup

```bash
git clone https://github.com/mxnyawi/datadog-assistant.git
cd datadog-assistant

# Run the logic tests anywhere (no Mac, no rumps needed):
python3 test_smoke.py

# Run the app for real (needs macOS + rumps + your own Datadog keys):
pip3 install rumps
DD_API_KEY=xxx DD_APP_KEY=yyy python3 datadog_assistant.py
```

A lot can be developed and tested on Linux because `rumps` is stubbed in the
tests — but **anything touching notifications, the menu bar, or `osascript`
needs a real Mac to verify.** Please say in your PR what you were able to test.

## Pull request workflow

1. **Fork** the repo and create a branch off `main`
   (`git checkout -b fix/short-description`).
2. Make your change. Match the surrounding style — it's plain, readable Python;
   no formatter is enforced, just keep it consistent and add comments where the
   *why* isn't obvious.
3. Run `python3 test_smoke.py` and add/extend a test if you changed logic.
4. Update **`README.md`** and **`config.example.json`** if you added or changed a
   config key or user-facing behaviour.
5. Open a PR using the template and describe **what** changed, **why**, and **how
   you tested** (especially whether it ran on a real Mac).

Small, focused PRs get reviewed fastest. If you're planning something big, open
an issue or discussion first so we can agree on the approach before you build it.

## Security & secrets

- **Never commit API keys, app keys, or Jira tokens.** `config.json` is already
  in `.gitignore`; keys belong in the macOS Keychain, env vars, or a password
  manager (see the README).
- If you find a security issue, please **don't** open a public issue — email the
  maintainer instead (see the profile on the repo).

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you're expected to keep things respectful and welcoming.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
