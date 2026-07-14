# Contributing to Datadog Assistant 🐶

Thanks for taking the time to contribute! This is a small, friendly project and
all kinds of help are welcome — bug reports, feature ideas, docs fixes, and code.

> ⚠️ This is an **unofficial** personal tool, not affiliated with or endorsed by
> Datadog, Inc. or Atlassian. Please keep contributions in that spirit.

## Ways to help

- 🐛 **Found a bug?** Open an [issue](https://github.com/mxnyawi/datadog-assistant/issues)
  using the Bug Report template. Grab logs from Console.app (filter on
  "Datadog Assistant") — redact your tokens/keys and any private monitor names
  before pasting.
- 💡 **Have an idea?** Open a Feature Request issue, or start a
  [Discussion](https://github.com/mxnyawi/datadog-assistant/discussions) if it's
  more of an open question.
- 📖 **Docs/typos?** Small README or comment fixes are very welcome — just open a PR.
- 💻 **Code?** See the workflow below.

## Project shape

The app is a native SwiftUI menu-bar app, shipped as a self-contained SwiftPM
package — no Xcode project, **no third-party dependencies** (AppKit / SwiftUI /
CryptoKit / Network only). Please keep it that way unless there's a strong
reason; zero deps is a feature.

- **`swift/Sources/DatadogAssistant/App/`** — app lifecycle, menu-bar panel,
  Settings and onboarding windows.
- **`swift/Sources/DatadogAssistant/Services/`** — one small file per concern:
  the Datadog client, SecretStore (on-device encrypted secrets), credentials
  and auth-mode logic, LastPass / GitHub CLI / Jira bridges, the poll loop
  (`SnapshotStore`).
- **`swift/Sources/DatadogAssistant/Views/`** — SwiftUI panel components
  (sparklines, monitor rows, tabs).
- **`swift/README.md`** — architecture notes, credential precedence, feature docs.
- **`legacy/python-app/`** — the archived original Python implementation.
  Historical reference only: no new features or fixes land there.

## Dev setup

Requires macOS 13+ and Swift 5.9+ (Xcode Command Line Tools are enough):

```bash
git clone https://github.com/mxnyawi/datadog-assistant.git
cd datadog-assistant/swift

swift build              # compile
DD_DEMO=1 swift run      # run on generated sample data — no credentials needed
./Scripts/build-app.sh   # assemble the .app bundle (ad-hoc signed)
```

To run against real data, either connect in-app (paste a Datadog access token)
or export env vars for the session: `DD_BEARER_TOKEN` (or
`DD_API_KEY`/`DD_APP_KEY`) and `DD_SITE`.

CI compiles the package and assembles the .app on a macOS runner for every PR
— that's the compile gate if you're developing on another OS.

## Pull request workflow

1. **Fork** the repo and create a branch off `main`
   (`git checkout -b fix/short-description`).
2. Make your change. Match the surrounding style — doc comments explain *why*,
   services stay small and single-purpose. No formatter is enforced; keep it
   consistent.
3. Make sure `swift build` passes (locally or via the CI job).
4. Update **`README.md`** and **`swift/README.md`** if you added or changed a
   credential flow, setting, or user-facing behaviour.
5. Open a PR using the template and describe **what** changed, **why**, and
   **how you tested** — especially whether notifications/menu-bar behaviour ran
   on a real Mac.

Small, focused PRs get reviewed fastest. If you're planning something big, open
an issue or discussion first so we can agree on the approach before you build it.

## Security & secrets

- **Never commit tokens, API keys, app keys, or Jira secrets.** The app stores
  secrets encrypted on-device (see `SecretStore.swift`); for dev, use env vars
  or a password-manager command.
- If you find a security issue, please **don't** open a public issue — follow
  [`SECURITY.md`](SECURITY.md) (GitHub private vulnerability reporting).

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you're expected to keep things respectful and welcoming.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
