# 🚀 Product Hunt launch kit — Datadog Assistant

Everything below is copy-paste ready. Gallery images are in
[`docs/launch/images/`](images/). Render them again any time with
`python3 docs/launch/shoot_launch.py`.

---

## ✅ Submit-page checklist

| Field | Value |
|---|---|
| **Name** | `Datadog Assistant` |
| **Tagline** (60 char max) | `Datadog alerts you literally can't miss` (39) |
| **Thumbnail / logo** | `images/ph-thumb.png` (square) |
| **Gallery** | `ph-01-hero` → `ph-02-unmissable` → `ph-03-one-click` → `ph-04-features` → `ph-05-preferences` (in this order) |
| **Topics** (pick 3) | Developer Tools · Mac · Monitoring |
| **Links** | Website / GitHub: `https://github.com/mxnyawi/datadog-assistant` |
| **Pricing** | Free (Open Source) |
| **Platforms** | macOS |

> Use the **first gallery image as the social/preview image** — it's the one
> that shows in the feed and on Twitter/X cards.

---

## Tagline — options (60 char limit)

Pick one (counts in parens):

1. `Datadog alerts you literally can't miss` (39) ← recommended
2. `Make Datadog alerts impossible to ignore` (41)
3. `Unmissable Datadog alerts, right in your menu bar` (49)
4. `Your Datadog on-call sidekick for the Mac menu bar` (50)

## Description (≈260 chars)

> A free, open-source macOS menu bar app that makes Datadog alerts impossible to
> ignore. See every monitor grouped by state, get an unmissable popup for P1s,
> live metric context and incidents, and file Jira tickets — all without leaving
> your menu bar.

---

## 💬 Maker's first comment

> Hey Product Hunt! 👋
>
> I'm an engineer who kept missing Datadog alerts — they'd get buried in email
> and Teams, and I'd find out a service was down from someone *else*. So I built
> the thing I wanted: a little 🐶 that lives in my Mac menu bar and makes alerts
> genuinely impossible to ignore.
>
> **What it does:**
> - 🚨 The menu bar icon flips the second a monitor fires — every monitor grouped
>   by state, one glance
> - 🛑 An unmissable modal popup for P1s that stays on screen until you act (macOS
>   can't silence it), plus native banners + sound for everything else
> - 📈 Live context on each alert — sparkline, current value vs threshold, how long
>   it's been firing, which hosts triggered
> - 🤫 No-Data triage so a dead host wakes you, but an expected-quiet monitor
>   doesn't
> - 🎫 One-click Jira tickets (manual or auto for P1/P2), 🔥 incidents, dashboards,
>   mute/snooze — all from the menu
>
> It's **free and open source (MIT)**, has zero runtime dependencies beyond
> `rumps`, and your API keys never leave your Mac — Keychain, env vars, or your
> password manager. Works with every Datadog site (US/EU/etc).
>
> It's an unofficial personal project, not affiliated with Datadog. I'd love your
> feedback, feature ideas, and PRs 🙏
>
> 👉 https://github.com/mxnyawi/datadog-assistant

---

## 🖼 Gallery captions (optional, per image)

1. **Hero** — Datadog alerts you literally can't miss.
2. **Unmissable** — Banners + a modal popup macOS can't silence.
3. **One click to act** — Priority, sparkline, hosts, mute, Jira, open — per monitor.
4. **Built for on-call** — Severity engine, live context, No-Data triage, Jira, incidents.
5. **Preferences** — Tune every behaviour from the menu bar, no config files.

---

## ⏰ Launch-day tips

- **Post at 12:01 AM PT** — PH days run on Pacific time; posting right at the
  start gives the full 24h to gather votes.
- **Tuesday–Thursday** generally see the most traffic (and the most competition);
  Saturday/Sunday are quieter if you'd rather a calmer launch.
- Line up your **first comment** (above) to post immediately.
- Have a **hunter** if you can — someone with a following hunting it helps, but a
  self-launch is totally fine.
- Reply to **every** comment on launch day; engagement is ranked.
- Cross-post once it's live (see `docs/launch/SHARE.md` if present, or the README's
  Contributing section): Show HN, r/devops, r/sre, r/Datadog, r/macapps, X/LinkedIn.
- Ask a handful of colleagues/friends to check it out through the day — but never
  ask for "upvotes" directly (against PH rules); ask for feedback.

## 🔗 First comment, short version (for HN / Reddit / X)

> A free macOS menu bar app that makes Datadog alerts impossible to ignore —
> unmissable popups for P1s, live metric context, incidents, one-click Jira
> tickets. Open source (MIT), keys stay on your Mac.
> https://github.com/mxnyawi/datadog-assistant
