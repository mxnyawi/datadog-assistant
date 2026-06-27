# Datadog Assistant — Marketing videos

Ten short promo videos for the **Datadog Assistant** menu-bar app, built with
[HyperFrames](https://github.com/heygen-com/hyperframes) (HTML → MP4).

Five features, each rendered in **two formats**:

| # | Feature | Headline | Landscape (16:9) | TikTok (9:16) |
|---|---------|----------|------------------|----------------|
| 1 | At-a-glance menu | *Every monitor, grouped by state* | `landscape/01-menu-overview` | `tiktok/01-menu-overview` |
| 2 | Can't-miss alerts | *A banner, a sound — and a modal you must dismiss* | `landscape/02-cant-miss-alerts` | `tiktok/02-cant-miss-alerts` |
| 3 | One-click actions | *Mute, ticket, or open — straight from the menu* | `landscape/03-one-click-actions` | `tiktok/03-one-click-actions` |
| 4 | Live context | *Priority, sparkline, threshold — and the hosts that fired* | `landscape/04-live-context` | `tiktok/04-live-context` |
| 5 | Deploy correlation | *See the deploy that fired the alert* | `landscape/05-deploy-correlation` | `tiktok/05-deploy-correlation` |

Each video is **9 seconds**, 30 fps. Landscape is 1920×1080; TikTok is 1080×1920.
The rendered MP4 lives in each composition's `renders/<slug>.mp4`.

## Structure

```
Marketing/
  build/
    generate.mjs     # generates all 10 index.html files (single source of truth)
    render-all.sh    # renders all 10 to MP4 (3 in parallel)
  landscape/<slug>/  # 16:9 compositions
    index.html  meta.json  hyperframes.json  vendor/gsap.min.js  renders/<slug>.mp4
  tiktok/<slug>/     # 9:16 compositions (same content, re-laid-out for vertical)
```

Every video shares one component design system and one GSAP timeline per feature;
**orientation is handled entirely in CSS**, so the landscape and TikTok cuts of a
feature are guaranteed to stay in sync. The UI styling mirrors the real app
mockups in [`../docs/mockup.html`](../docs/mockup.html).

## Rebuild / re-render

```bash
node Marketing/build/generate.mjs   # regenerate the HTML from build/generate.mjs
bash Marketing/build/render-all.sh  # re-render all 10 MP4s
```

Notes for headless / sandboxed environments:

- GSAP is **vendored** per composition (`vendor/gsap.min.js`) so rendering needs no CDN.
- Point HyperFrames at an existing Chromium when there's no download access:
  `export HYPERFRAMES_BROWSER_PATH=/path/to/chrome`.

To edit a video, change `build/generate.mjs` (content, timing, layout) and
regenerate — don't hand-edit the generated `index.html` files.
