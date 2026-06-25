# PRD — Unified `.app` + onboarding GUI (with GUI LastPass auth)

**Status:** Draft for review
**Branch:** `claude/app-bundle-gui-installer`
**Author:** Claude (exploration + proposal)
**Date:** 2026-06-25

---

## 1. Summary

Today the project ships **two things that aren't really one product**: a menu-bar
app that runs as a bare Python script, and a separate installer (native
AppleScript *or* a Tkinter wizard) that sets up a venv + LaunchAgent. The
installers don't support LastPass at all, the running app isn't a real bundle
(so it shows as "Python" and can't have clickable notifications), and LastPass
auth still forces the user into Terminal to run `lpass login`.

This PRD proposes a **single, self-contained `Datadog Assistant.app`** that:

1. The user **downloads and double-clicks** — no Terminal, ever.
2. On first launch shows a **beautiful, modern onboarding GUI** that walks
   through the entire setup (region → auth → options → install).
3. Supports **GUI-driven LastPass authentication** — enter email + master
   password (+ MFA) *in the app*, which drives the `lpass` CLI under the hood.
4. Offers a **"stay logged in" (never-expire)** option, including an opt-in path
   that survives reboots.
5. After onboarding, **installs itself** as a login item and runs as the menu-bar
   app — the same bundle, now in "run" mode.

It folds the `.app` bundling work (already on this branch) and the GUI installer
into one artifact.

---

## 2. Goals / Non-goals

### Goals
- One downloadable `.app`; double-click → guided setup → menu-bar app. Zero Terminal.
- A genuinely modern UI: smooth transitions, real layout, not stock Tkinter widgets.
- First-class **LastPass** support in the GUI (currently CLI-only), including
  **login from inside the app**.
- **Never-expire** LastPass sessions, with an honest story about reboots.
- Preserve existing auth modes (API keys, OAuth) and all current install behavior
  (Keychain storage, LaunchAgent, start-at-login).
- Keep secrets off disk: master password and keys never land in `config.json`.

### Non-goals (this iteration)
- Code-signing / notarization (tracked separately; the app stays unsigned →
  right-click-Open on first run). Worth doing later but out of scope here.
- Replacing the underlying menu-bar app logic — only how it's packaged, launched,
  and onboarded.
- Windows/Linux (macOS-only product).
- Migrating away from `lpass` (the LastPass CLI is EOL-adjacent but still the only
  scriptable option; see Risks).

---

## 3. Current state (what exists today)

| Piece | File(s) | Auth modes | Notes |
|---|---|---|---|
| Menu-bar app | `datadog_assistant.py` | keys / oauth / lastpass | Runs as a bare script via LaunchAgent. Now bundleable via `setup.py` (this branch). |
| Native installer | `installer/install.applescript` (+ `do_install.sh`) | keys / oauth | No LastPass. `osacompile` → `.app`. |
| Tkinter installer | `installer/install_gui.py` (+ `build.sh`) | keys / oauth | No LastPass. 5-step wizard (Welcome/Region/Sign in/Options/Install). Stock Tk styling. |
| CLI installer | `install.sh` | keys / oauth / **lastpass** | Only path with LastPass + `LPASS_AGENT_TIMEOUT`. |

**LastPass internals** (`datadog_assistant.py`):
- `_find_lpass()` locates the `lpass` binary (Homebrew paths LaunchAgents miss).
- `lpass_logged_in()` → `lpass status`; `lpass_get(entry, field)` → `lpass show
  --field` / `--notes` (key=value). Cached with a TTL.
- Auth mode `lastpass` reads `lastpass.entry` + field names from config; Jira
  OAuth secrets are injected in-memory only (`_lp_*`), never persisted.
- **The app never logs in** — it assumes a prior `lpass login`.

**Never-expire today:** `install.sh` writes `LPASS_AGENT_TIMEOUT` to the shell rc
and the LaunchAgent plist `EnvironmentVariables`. `0` = agent never times out
**within a session**. It does **not** persist across reboot/logout (the agent's
in-memory key is gone; `lpass login` is required again).

---

## 4. Proposed architecture

### 4.1 One bundle, two modes ("self-onboarding app")

`Datadog Assistant.app` runs in one of two modes, decided at launch:

- **Onboarding mode** — when no valid config exists (first run, or launched from
  `/Applications` before setup). Shows the GUI. On completion it:
  - writes `config.json`, stores secrets (Keychain), sets up the venv if needed,
  - installs the LaunchAgent pointing at **this same bundle's executable**,
  - relaunches itself in run mode.
- **Run mode** — when config is valid. Boots straight into the rumps menu-bar app
  (current behavior). `LSUIElement` keeps it menu-bar-only.

A `--onboard` flag (and a "Re-run setup" menu item) can force onboarding later.

> **Why one bundle?** It's the cleanest "download → double-click → done" UX, gives
> the running process a real bundle identity (clickable notifications, proper name/
> icon), and means there's a single thing to build, sign, and ship.

**Alternative (lower-risk fallback):** keep a *separate* installer `.app` that
drops the menu-bar `.app` into `/Applications`. Two bundles, closer to today's
model, but it doesn't really "combine" them and doubles the signing/build surface.
Recommended only if the single-bundle mode-switch proves fragile.

### 4.2 GUI technology

| Option | Look & feel | Effort | Bundling | Verdict |
|---|---|---|---|---|
| **pywebview (HTML/CSS/JS in WKWebView)** | Full modern design control — CSS animations, gradients, smooth transitions | Medium | py2app-friendly; Python backend drives steps | **Recommended.** Best polish-per-effort for a Python app. |
| SwiftUI onboarding (native) | Maximum native polish | High | Separate Swift target + IPC to Python | Best looks, but adds a toolchain + cross-language glue. Consider later. |
| Tkinter (current), restyled | Limited; never truly "modern" | Low | Trivial | Rejected — can't hit the "beautiful/smooth" bar. |

**Recommendation: pywebview.** The frontend is HTML/CSS/JS (designed to feel like
a modern macOS onboarding — large type, motion, a progress rail), and a small
Python API bridge runs the real install steps and streams progress back. It bundles
cleanly with py2app and reuses all existing install logic.

### 4.3 Reusing install logic

Refactor the install steps (`do_install.sh` / `install_gui.py` `Installer`) into a
**single Python module** (`installer/engine.py`) with typed steps:
`ensure_python` → `ensure_venv` → `install_deps` → `write_config` →
`store_secrets` → `setup_lastpass` (new) → `install_launchagent` → `launch`.
Both the GUI bridge and a headless/CLI entry call the same engine, so behavior can't
drift between paths (the same problem PR #2 fixed for `install.sh`).

---

## 5. LastPass: GUI auth + never-expire

### 5.1 GUI login flow (no Terminal)

The onboarding GUI's "LastPass" path:

1. **Ensure `lpass`.** Detect via `_find_lpass()`. If missing: offer to install
   (Homebrew if present; otherwise guide, or ship a bundled binary — see Risks).
2. **Login screen** — collect **email** + **master password** in the GUI. Backend
   runs login non-interactively (proposed; verify on macOS):
   ```
   LPASS_DISABLE_PINENTRY=1  printf '%s' "$MASTER" | lpass login --trust <email>
   ```
   `--trust` registers the device so MFA isn't re-prompted next time.
3. **MFA step (conditional)** — if the account requires it, `lpass` asks for a code
   on stdin; the GUI shows a second field and pipes the OTP through.
4. **Never-expire** — set `LPASS_AGENT_TIMEOUT=0` (shell rc + plist env, as today).
5. **Pick the entry + fields** — list candidates with `lpass ls` and let the user
   choose the entry, with smart defaults for field names (`datadogAPIKey`, etc.).
   Validate by reading the keys back before finishing.
6. Write `auth: lastpass` + `lastpass{ entry, *_field }` to config. **No master
   password or keys on disk.**

### 5.2 "Never expire" — the honest design

`LPASS_AGENT_TIMEOUT=0` keeps the session alive **until logout/reboot**. To make it
feel "never expires" to the user, two levels:

- **Level 1 (default, no extra secrets):** set timeout `0`. After a reboot the app
  detects a logged-out agent (`lpass_logged_in()` already does this) and surfaces a
  lightweight **"Unlock LastPass" prompt** from the menu bar (re-enter master
  password once). Smooth, and stores nothing extra.
- **Level 2 (opt-in, survives reboot):** with explicit consent, store the master
  password in the **macOS Keychain** and add a tiny **boot helper** (LaunchAgent)
  that re-runs `lpass login` non-interactively at login. True hands-off
  persistence, at the cost of a high-value secret living in the Keychain.
  Clearly labeled, off by default, and gated behind a security explainer.

This needs a security review sign-off before Level 2 ships.

---

## 6. Security considerations

- **Master password**: in-memory by default; only persisted (Keychain) under the
  explicit Level-2 opt-in. Never in `config.json`, never logged.
- **No shell injection**: all `lpass` calls use argv arrays (as the codebase
  already does); the password goes via stdin/env, never interpolated into a string.
- **Bundled `lpass`**: `lastpass-cli` is **GPLv2** — bundling it inside our
  (MIT) `.app` has licensing implications. Either keep the Homebrew-install path,
  or ship `lpass` as a clearly-attributed, separately-licensed component. **Open
  question — needs a decision.**
- **Unsigned app**: first-run Gatekeeper friction (right-click → Open). Onboarding
  should explain this up front. Notarization is the real fix (future work).
- Reuse the existing security posture: `umask 077` on config, Keychain for keys.

---

## 7. Build & distribution

- `setup.py` (py2app, already on this branch) gains the onboarding entry point and
  bundles the GUI assets (HTML/CSS/JS) + pywebview.
- `installer/build_menubar_app.sh` becomes the single build script producing the
  unified `.app`; the old PyInstaller/AppleScript installer builds are retired (or
  kept only as the fallback model from §4.1).
- Release: zip the `.app`, publish with the existing SHA-256 checksum flow
  (`installer/release.sh`).
- **Build must run on a Mac** (py2app + WKWebView). CI on Linux keeps doing
  `py_compile` + smoke; a Mac CI runner (optional) could validate the bundle.

---

## 8. Phased delivery

1. **Phase 0 — foundation (done on this branch):** real `.app` bundle + clickable
   notifications + `setup.py`.
2. **Phase 1 — install engine:** extract `installer/engine.py`; unify the existing
   keys/oauth install paths on it (no UI change yet). Fully testable on Linux.
3. **Phase 2 — GUI shell:** pywebview onboarding for keys/oauth, self-onboarding
   mode-switch in the bundle. Replaces the Tkinter wizard.
4. **Phase 3 — LastPass in the GUI:** login flow + entry/field picker + never-expire
   Level 1.
5. **Phase 4 — never-expire Level 2:** opt-in Keychain + boot helper, behind a
   security review.
6. **Phase 5 — polish & retire:** animations/copy, remove the old installers, docs.

Each phase is independently shippable and reviewable.

---

## 9. Open questions (need your call)

1. **Single self-onboarding bundle (§4.1 recommended) vs. separate installer app?**
2. **GUI tech: pywebview (recommended) vs. invest in SwiftUI for max polish?**
3. **Bundle `lpass` (GPL) in the app, or require Homebrew** for the install?
4. **Ship never-expire Level 2** (master password in Keychain + boot re-login), or
   stop at Level 1 (re-prompt after reboot)?
5. **Retire the Tkinter + AppleScript installers**, or keep one as a fallback?

---

## 10. Success criteria

- A new user downloads one file, double-clicks, and reaches a working menu-bar app
  (with their chosen auth) **without opening Terminal**.
- LastPass users authenticate entirely in the GUI and, with never-expire on, aren't
  re-prompted during normal use.
- The running app has its own identity (name/icon) and **notification clicks open
  the monitor**.
- No secret (master password, API/App keys) is written to `config.json`.
