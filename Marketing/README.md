# Datadog Assistant — Marketing videos

Story-driven promo videos for the **Datadog Assistant** menu-bar app, built with
[HyperFrames](https://github.com/heygen-com/hyperframes) (HTML → MP4), with a
**synthesized soundtrack + synced sound effects** mixed in at render time.

The five product features are grouped into **3 narrative videos**, each rendered in
**two formats** (landscape 16:9 + TikTok 9:16) — **6 videos** total. Each is ~16.5s,
30 fps. Landscape = 1920×1080; TikTok = 1080×1920.

| # | Story | Folds in | Arc | Files |
|---|-------|----------|-----|-------|
| 1 | **Know the moment it breaks** | at-a-glance menu + live context | calm desktop → a monitor fires (badge flips ‼️, sound) → menu grouped by state → drill in: priority, **live metric graph** breaching the threshold, triggered hosts | `landscape/01-detect-and-triage`, `tiktok/01-detect-and-triage` |
| 2 | **Impossible to ignore** | banner + sound + critical modal | working → alert banner + recovery chime → a P1 fires → screen dims, **critical modal slams in** (impact hit), re-nags until you act | `landscape/02-impossible-to-ignore`, `tiktok/02-impossible-to-ignore` |
| 3 | **From alert to fix in seconds** | service context + deploy correlation + one-click actions | **service context** (repo/runbook/dashboard) → the **deploy that did it** highlights → cursor **mutes in one click**, Jira ticket toast | `landscape/03-alert-to-fix`, `tiktok/03-alert-to-fix` |

The rendered MP4 lives in each composition's `renders/<slug>.mp4`.

## What makes them realistic

- Full macOS staging: menu bar with live status icons, dock, layered wallpaper, film grain + vignette.
- A **live SVG metric chart** that draws itself, counts the value up, and breaches a red threshold line.
- Authentic Datadog-style UI: monitors grouped by state with inline sparklines + severity dots, service-context chips, deploy correlation, an action flyout with a moving **cursor** that clicks and fires toasts.
- Scene-to-scene **white-flash + whoosh** transitions and a count-in title / brand-lockup outro.
- **Audio:** a per-story synthesized music bed (tense / urgent / uplifting) + bundled SFX
  (notification, chime, pop, click, impact, ping, whoosh, sparkle, riser) synced to each beat.

## Structure

```
Marketing/
  build/
    generate.mjs       # generates all 6 index.html files (single source of truth)
    synth-bgm.sh        # synthesizes the 3 music beds with ffmpeg (tense/urgent/uplift)
    render-all.sh       # renders all 6 to MP4 (3 in parallel)
    assets/{bgm,sfx}/   # source audio the generator copies into each composition
  landscape/<slug>/  &  tiktok/<slug>/
    index.html  meta.json  hyperframes.json
    vendor/gsap.min.js
    assets/bgm/bed.wav  assets/sfx/*.mp3
    renders/<slug>.mp4
```

Each story shares one component design system and one GSAP timeline; **orientation is
CSS-only**, so the landscape and TikTok cuts of a story stay in lockstep.

## Rebuild / re-render

```bash
bash Marketing/build/synth-bgm.sh tense  16.5 Marketing/build/assets/bgm/tense.wav   # (+ urgent, uplift)
node Marketing/build/generate.mjs    # regenerate the HTML + copy assets
bash Marketing/build/render-all.sh   # re-render all 6 MP4s (audio muxed in)
```

Notes for headless / sandboxed environments:

- GSAP is **vendored** per composition (`vendor/gsap.min.js`) so rendering needs no CDN.
- Point HyperFrames at an existing Chromium when there's no download access:
  `export HYPERFRAMES_BROWSER_PATH=/path/to/chrome`.
- SFX are sourced from the HyperFrames `hyperframes-media` bundled library; the music
  beds are synthesized offline (no API key). With a HeyGen key, real catalog music/SFX
  could be swapped in via `media-use`.

To edit a video, change `build/generate.mjs` (content, timing, layout, audio cues) and
regenerate — don't hand-edit the generated `index.html` files.
