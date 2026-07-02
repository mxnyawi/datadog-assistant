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
| `api_key_cmd`/`app_key_cmd` (any password-manager CLI) | ❌ | Add two optional "command" fields to Settings → Source; run via `Process`, stdout = secret, cache 15 min (port of `secret_from_cmd`) |
| Datadog OAuth (authorization-code + PKCE) | ❌ | Biggest auth gap. Port of `_datadog_oauth_browser_flow`: local callback server on 127.0.0.1:8918 (`NWListener` or `SwiftNIO`-free raw socket), S256 challenge, scopes list, region auto-detect from the redirect's `domain` param, refresh-token rotation in Keychain `datadog-assistant-oauth` |
| Connection test (mode, site, monitor count, incident scope) | 🟡 | LastPass Test button validates keys via `/api/v1/validate`; add a general "Test connection" to Settings → Source reporting monitor count + incidents scope |
| Single-instance lock | ❌ | `flock` on a lock file in Application Support at launch; quit if held |

## Datadog data & links

| Feature | Status | Notes / implementation plan |
|---|---|---|
| Site picker (com/eu/us3/us5/ap1/gov) | ✅ | Settings → Source + LastPass setup sheet |
| **Org subdomain (`app_subdomain`)** | ✅ | Settings → Source; all browser links use `<subdomain>.<site>` so vanity-subdomain orgs keep their session (env `DD_APP_SUBDOMAIN`) |
| Subdomain guess from org name (GET /org) | ❌ | Nice-to-have: fetch `/api/v1/org`, sanitize the name, offer it as the field's placeholder |
| Browser choice (open links in Chrome etc.) | ❌ | Add a Settings picker listing browsers (`NSWorkspace.urlsForApplications(toOpen:)`); open via `NSWorkspace.open(_:withApplicationAt:)` |
| Monitor fetch: pagination (200/page, cap) | ❌ | Current fetch is single-request. Add `page`/`page_size` loop in `fetchMonitorsPage` with a hard page cap — needed for very large orgs |
| Tag filter (OR semantics, server-side) | ✅ | FilterBar dropdown grouped by tag key + Settings → Filters; per-tag fetch + dedupe |
| Name filter (substring, server-side) | ✅ | Settings → Filters (panel List tab also has ad-hoc search) |
| Retry with backoff on transient network errors | ❌ | Wrap `session.data(for:)` in a 3-attempt retry (1/2/3 s) for timeout/connection-reset |
| Gzip, 30 s timeouts | ✅ | URLSession defaults cover it |

## Monitors UI

| Feature | Status | Notes / implementation plan |
|---|---|---|
| State grouping (alert/warn/no-data/ok/muted), worst first | ✅ | StateSection + MonitorListSection groups |
| Group order / max-per-group / hide-OK config | ❌ | Low value in the panel UI (scrolls); add "Show OK monitors" toggle if requested |
| Per-monitor: open in Datadog, mute 1 h | ✅ | Row actions |
| Mute 4 h / 24 h / forever + **unmute** | ❌ | Replace the "Mute 1h" button with a small Menu (1 h/4 h/24 h/forever/Unmute); `mute` API already takes any end, add POST `/monitor/{id}/unmute` to DataSource |
| Local rename (aliases) + reset | ❌ | `aliases: [Int: String]` in UserDefaults; rename field in the expanded row; use display name everywhere incl. notifications |
| Monitor create (name/query/message) | ❌ | Rarely used from a menu bar; if wanted: small form window POSTing `/api/v1/monitor` with `created_by:datadog-assistant` tag |
| Monitor delete (type DELETE to confirm) | ❌ | Destructive; add to expanded row behind a confirmation sheet requiring typed DELETE |
| Priority detection from tags / "[P1]" in name | 🟡 | Swift reads the `priority` field only; extend to `priority:pN` tag and `[PN]` name prefix (port `parse_priority`) |
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
| Modal style (unmissable NSAlert popup) | ❌ | Add style picker (banner/modal/both); modal = `NSAlert` on a floating panel with Open/Dismiss, auto-dismiss ~5 min |
| Per-priority severity rules (style/renotify/icon per P1..P5) | ❌ | Add `severityRules` to NotificationSettings (P1/P2/P3 rows with style + renotify overrides); merge before delivering |
| No-data notifications (gated by triage) | ❌ | Depends on No-Data triage (below) |
| Notify when mute lifts and still firing | ❌ | Track muted→unmuted transitions in the store diff |
| Daily digest (morning summary banner) | ❌ | `digestHour: Int?` setting; on poll, if past the hour and not yet sent today (persisted date), post summary notification |
| Test notification menu item | ❌ | One button in Settings → Notifications firing a sample banner |

## Triage & grouping intelligence

| Feature | Status | Notes / implementation plan |
|---|---|---|
| No-Data triage (broken vs quiet) | ❌ | Port `_triage_no_data`: quiet if `on_missing_data` resolves/OK, event-stream monitor types, stale > 48 h, or metric probe silent; broken if probe shows data-then-stop. Needs `options.notify_no_data`, `on_missing_data`, `type` decoded from the monitor DTO + a capped probe via `/api/v1/query` |
| DLQ grouping (dead-letter monitors, own section) | ❌ | Name/query/tag substring match against configurable patterns; dedicated panel section listing urgent DLQ monitors first (exclusive mode removes them from normal groups) |
| Service clusters ("payments has 3 firing") | ✅ | ClusterChips (Swift-only equivalent of blast-radius insight) |
| Service context (repo/runbook/docs/on-call links via Software Catalog, message links, version/commit) | ❌ | Large port: GET `/api/v2/services/definitions` hourly, parse links per schema version; merge with links scraped from monitor message; render in expanded row. Worth doing as its own milestone |
| Deploy correlation ("shipped X min before this alert") | ✅ | Suspect-deploy callout on rows + Changes tab (GitHub merges + Datadog deploy events) — equivalent of Python's deploy correlation |
| Deploy events per service w/ cache budget | 🟡 | Swift fetches org-wide deployment-tagged events (6 h); Python queries per-service with TTL cache. Extend if event volume becomes a problem |
| Incidents section (active, severity-sorted) | ✅ | IncidentsSection (v2 API, best-effort) |

## Jira

| Feature | Status | Notes / implementation plan |
|---|---|---|
| API-token auth (email + token, Basic) | ✅ | Settings → Jira; token env → **LastPass note `jiraToken` field** → Keychain |
| Create ticket per monitor (manual) | ✅ | Row action; summary `[P1] name`, description with state/duration/hosts/deep-link, `datadog-assistant` label |
| **Ticket↔monitor mapping ("Open PROJ-123")** | ✅ | Persisted map; row shows Open instead of re-creating |
| **Auto-create on alert (P1 / P1+P2) + dedupe** | ✅ | Settings picker; fires on transition, announces with a notification that opens the ticket |
| Dedupe via JQL search (`dd-monitor-<id>` label, status != Done) | 🟡 | Swift dedupes locally (persisted map). Add the JQL check so tickets created elsewhere / reopened states are respected: GET `/rest/api/3/search/jql?jql=labels="dd-monitor-<id>" AND statusCategory != Done`; also add the `dd-monitor-<id>` label on create |
| Auto-labels from monitor tags | ❌ | Map each tag to `datadog-alert-<tag>` (sanitized) when creating; honor tag filter |
| Jira OAuth (3LO via auth.atlassian.com, cloud_id) | ❌ | Only needed for orgs that forbid API tokens: callback server on 8917, client id+secret (LastPass `jiraClientID`/`jiraClientSecret` fields), accessible-resources → cloud_id, Bearer against api.atlassian.com |
| Jira connection test (whoami, visible projects, project access) | ❌ | Button in Settings → Jira calling `/rest/api/3/myself` + `/project/search`, reporting in-window |

## App shell & misc

| Feature | Status | Notes / implementation plan |
|---|---|---|
| Menu-bar icon states (error/snoozed/alert-with-count/warn/ok) | ✅ | MenuBarController badge (SF-symbol style rather than emoji) |
| Snooze all (30 m/1 h/4 h/rest of day) + wake | ✅ | Snooze tab (API downtime — stronger than Python's local-only snooze) |
| Quick links + custom links + auto dashboard links | ❌ | Tools tab has Open Datadog; add: configurable quick-links list, and a "My dashboards" section fetched hourly from `/api/v1/dashboard` (cap 8) |
| Refresh interval setting | 🟡 | Swift uses adaptive 15 s/60 s cadence (better than fixed); add an override picker only if requested |
| Refresh now | ✅ | Tools tab + header |
| Disk cache for instant render on launch | ✅ | Swift-only bonus |
| App Nap prevention | ❌ | `ProcessInfo.beginActivity(.userInitiated)` held for app lifetime so the poll timer isn't throttled |
| Startup log for bundle diagnostics | 🟡 | LastPass has transcript logging; add a general `~/.datadog-assistant/startup.log` appender if launch issues appear |
| Open config file | n/a | Swift persists via UserDefaults; expose `defaults export` hint or a JSON export if needed |
| Onboarding GUI (first-run wizard) | 🟡 | Python has a pywebview onboarding app; Swift's Settings + LastPass setup sheet covers it — a first-launch "welcome" sheet pointing at Settings would close the gap |
| Daily digest / demo mode / dog-themed copy | 🟡 | Demo mode exists in MockDataSource; digest missing (see Notifications) |

## Suggested next milestones (in value order)

1. **Mute menu (4 h/24 h/forever/unmute)** — small, high daily value.
2. **No-Data triage** — kills the noisiest false-positive class.
3. **Jira JQL dedupe + auto-labels + connection test** — completes the ticket loop.
4. **Modal notification style + per-priority severity rules** — the "unmissable P1" behavior.
5. **Quick links + my dashboards** — one-tap navigation.
6. **Service context (Software Catalog links)** — biggest remaining port, own milestone.
7. **Datadog OAuth PKCE** — only if key-less orgs need it.
