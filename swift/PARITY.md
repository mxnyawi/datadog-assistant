# Feature parity: Python app → Swift app

Every feature of `datadog_assistant.py` (the Python menu-bar app), its status
in this Swift app, and how the missing ones should be implemented. Legend:
✅ done · 🟡 partial · ❌ missing.

## Credentials & auth

| Feature | Status | Notes / implementation plan |
|---|---|---|
| API + App keys (Keychain, same service names) | ✅ | `Credentials.swift`; env `DD_API_KEY`/`DD_APP_KEY` win |
| LastPass CLI mode (shared secure note) | ✅ | Same note format/fields as Python; guided install/login/entry setup with Test diagnostics; entry looked up by lpass ID |
| Explicit auth-source selection | ✅ | `AuthMode` (sample/keychain/lastpass) — no silent Keychain fallback (Python infers from config instead) |
| `api_key_cmd`/`app_key_cmd` (any password-manager CLI) | ✅ | SecretCommand (sh -c, stdout = secret, 15-min cache); fields in Settings → Source (Keychain mode) |
| Datadog OAuth (authorization-code + PKCE) | ❌ | Biggest auth gap. Port of `_datadog_oauth_browser_flow`: local callback server on 127.0.0.1:8918 (`NWListener` or `SwiftNIO`-free raw socket), S256 challenge, scopes list, region auto-detect from the redirect's `domain` param, refresh-token rotation in Keychain `datadog-assistant-oauth` |
| Connection test (mode, site, monitor count, incident scope) | 🟡 | LastPass Test button validates keys via `/api/v1/validate`; add a general "Test connection" to Settings → Source reporting monitor count + incidents scope |
| Single-instance lock | ✅ | flock on Application Support/DatadogAssistant/app.lock at launch |

## Datadog data & links

| Feature | Status | Notes / implementation plan |
|---|---|---|
| Site picker (com/eu/us3/us5/ap1/gov) | ✅ | Settings → Source + LastPass setup sheet |
| **Org subdomain (`app_subdomain`)** | ✅ | Settings → Source; all browser links use `<subdomain>.<site>` so vanity-subdomain orgs keep their session (env `DD_APP_SUBDOMAIN`) |
| Subdomain guess from org name (GET /org) | ❌ | Nice-to-have: fetch `/api/v1/org`, sanitize the name, offer it as the field's placeholder |
| Browser choice (open links in Chrome etc.) | ✅ | LinkOpener + Settings → Source dropdown of installed browsers; all link opens routed through it |
| Monitor fetch: pagination (200/page, cap) | ✅ | 200/page loop, 500-page cap |
| Tag filter (OR semantics, server-side) | ✅ | FilterBar dropdown grouped by tag key + Settings → Filters; per-tag fetch + dedupe |
| Name filter (substring, server-side) | ✅ | Settings → Filters (panel List tab also has ad-hoc search) |
| Retry with backoff on transient network errors | ✅ | 3 attempts, growing backoff; HTTP errors surface immediately |
| Gzip, 30 s timeouts | ✅ | URLSession defaults cover it |

## Monitors UI

| Feature | Status | Notes / implementation plan |
|---|---|---|
| State grouping (alert/warn/no-data/ok/muted), worst first | ✅ | StateSection + MonitorListSection groups |
| Group order / max-per-group / hide-OK config | ❌ | Low value in the panel UI (scrolls); add "Show OK monitors" toggle if requested |
| Per-monitor: open in Datadog, mute 1 h | ✅ | Row actions |
| Mute 4 h / 24 h / forever + **unmute** | ✅ | Mute dropdown on every row; Unmute for muted monitors (/unmute endpoint) |
| Local rename (aliases) + reset | ✅ | Inline editor in the expanded row; alias applied after every fetch (rows, notifications, Jira); one-tap reset |
| Monitor create (name/query/message) | ❌ | Rarely used from a menu bar; if wanted: small form window POSTing `/api/v1/monitor` with `created_by:datadog-assistant` tag |
| Monitor delete (type DELETE to confirm) | ❌ | Destructive; add to expanded row behind a confirmation sheet requiring typed DELETE |
| Priority detection from tags / "[P1]" in name | ✅ | Field → priority:pN tag → [PN] in name |
| Duplicate-name disambiguation | ✅ | SwiftUI lists key by monitor id, not title (rumps workaround not needed) |
| Sparklines with threshold line + deploy markers | ✅ | Richer than Python's unicode sparklines |
| "×N vs last week" delta | ✅ | Swift-only bonus (week_before query) |
| Triggered groups list | ✅ | Expanded row (`server.rack` line) |
| Firing duration | ✅ | Expanded row + hero card |

## Notifications

| Feature | Status | Notes / implementation plan |
|---|---|---|
| Master enable, warn, recovery toggles | ✅ | Settings → Notifications |
| Sound on/off + system-sound dropdown w/ preview | ✅ | NSSound for named sounds (UNNotificationSound can't reach /System/Library/Sounds) |
| Re-notify while still alerting (interval dropdown) | ✅ | Per-poll nag, silent while snoozed |
| Actionable banners (Mute 1 h / Open) | ✅ | Swift-only bonus (UNNotification actions) |
| Modal style (unmissable popup) | ✅ | Floating always-on-top alert window, Open/Dismiss, 5-min auto-dismiss; style picker banner/modal/both |
| Per-priority severity rules (style/renotify per P1..P3) | ✅ | Same defaults as Python (P1 both/10m, P2 both/30m, P3 banner/60m); editable in Settings |
| No-data notifications (gated by triage) | ✅ | Broken-No-Data transitions notify with the triage reason; toggle in Settings |
| Notify when mute lifts and still firing | ❌ | Track muted→unmuted transitions in the store diff |
| Daily digest (morning summary banner) | ✅ | Hour picker in Settings; once/day summary |
| Test notification menu item | ✅ | Settings → Notifications button (banner + modal per style) |

## Triage & grouping intelligence

| Feature | Status | Notes / implementation plan |
|---|---|---|
| No-Data triage (broken vs quiet) | ✅ | Full ladder incl. live metric probe (6/poll, cached); quiet group in the list, reasons in rows and notifications |
| DLQ grouping (dead-letter monitors, own section) | ✅ | Pattern match on name/tags/query; 💀 section (firing rows + healthy count), exclusive mode |
| Service clusters ("payments has 3 firing") | ✅ | ClusterChips (Swift-only equivalent of blast-radius insight) |
| Service context (repo/runbook/docs/on-call links via Software Catalog, message links, version/commit) | ❌ | Large port: GET `/api/v2/services/definitions` hourly, parse links per schema version; merge with links scraped from monitor message; render in expanded row. Worth doing as its own milestone |
| Deploy correlation ("shipped X min before this alert") | ✅ | Suspect-deploy callout on rows + Changes tab (GitHub merges + Datadog deploy events) — equivalent of Python's deploy correlation |
| Deploy events per service w/ cache budget | 🟡 | Swift fetches org-wide deployment-tagged events (6 h); Python queries per-service with TTL cache. Extend if event volume becomes a problem |
| Incidents section (active, severity-sorted) | ✅ | IncidentsSection (v2 API, best-effort) |

## Jira

| Feature | Status | Notes / implementation plan |
|---|---|---|
| API-token auth (email + token, Basic) | ✅ | Legacy fallback mode (OAuth is the default) |
| Create ticket per monitor (manual) | ✅ | Row action; summary `[P1] name`, description with state/duration/hosts/deep-link, `datadog-assistant` label |
| **Ticket↔monitor mapping ("Open PROJ-123")** | ✅ | Persisted map; row shows Open instead of re-creating |
| **Auto-create on alert (P1 / P1+P2) + dedupe** | ✅ | Settings picker; fires on transition, announces with a notification that opens the ticket |
| Dedupe via JQL search (`dd-monitor-<id>` label, status != Done) | ✅ | createIssue adopts open tickets found via JQL before creating; dd-monitor-<id> label on create |
| Auto-labels from monitor tags | ✅ | datadog-alert-<tag> (sanitized) per tag |
| Jira OAuth (3LO via auth.atlassian.com, cloud_id) | ✅ | **Default auth mode.** Client ID/secret from LastPass note (jiraClientID/jiraClientSecret) or manual; callback on 8917; refresh-token rotation; Bearer via api.atlassian.com/ex/jira/<cloudID> |
| Jira connection test (whoami, visible projects, project access) | ✅ | Test button in Settings → Jira |

## GitHub (Swift-only feature, no Python equivalent)

| Feature | Status | Notes |
|---|---|---|
| Merge/deploy correlation + CI pipeline runs (Changes tab) | ✅ | REST via token |
| Token from the gh CLI (`gh auth token`) | ✅ | Zero-setup when `gh` is logged in; chain: env → LastPass note → Keychain → gh CLI |
| Repo suggestions from `gh repo list` | ✅ | "Add from your gh repos…" menu in Settings → GitHub |

## App shell & misc

| Feature | Status | Notes / implementation plan |
|---|---|---|
| Menu-bar icon states (error/snoozed/alert-with-count/warn/ok) | ✅ | MenuBarController badge (SF-symbol style rather than emoji) |
| Snooze all (30 m/1 h/4 h/rest of day) + wake | ✅ | Snooze tab (API downtime — stronger than Python's local-only snooze) |
| Quick links + auto dashboard links | ✅ | Tools tab: 6 standard links + My dashboards (hourly fetch, cap 8). Custom links list not yet exposed in UI |
| Refresh interval setting | 🟡 | Swift uses adaptive 15 s/60 s cadence (better than fixed); add an override picker only if requested |
| Refresh now | ✅ | Tools tab + header |
| Disk cache for instant render on launch | ✅ | Swift-only bonus |
| App Nap prevention | ✅ | ProcessInfo activity token held for app lifetime |
| Startup log for bundle diagnostics | 🟡 | LastPass has transcript logging; add a general `~/.datadog-assistant/startup.log` appender if launch issues appear |
| Open config file | n/a | Swift persists via UserDefaults; expose `defaults export` hint or a JSON export if needed |
| Onboarding GUI (first-run wizard) | 🟡 | Python has a pywebview onboarding app; Swift's Settings + LastPass setup sheet covers it — a first-launch "welcome" sheet pointing at Settings would close the gap |
| Daily digest / demo mode / dog-themed copy | ✅ | Demo mode in MockDataSource; daily digest shipped (hour picker in Settings → Notifications) |

## Remaining gaps (in value order)

1. **Service context** (Software Catalog repo/runbook/on-call links, message
   links, version/commit) — the biggest remaining port; own milestone.
2. **Datadog OAuth PKCE** — only needed for key-less orgs (LastPass/keys
   cover today's use).
3. **Notify when a mute lifts and the monitor is still firing** — small store
   diff addition.
4. **Monitor create / delete** — rarely used from a menu bar; delete needs a
   typed-DELETE confirmation.
5. Cosmetics/config nits: subdomain guess from GET /org, custom quick-links
   list UI, group order / max-per-group / hide-OK settings, general Datadog
   connection test button.
