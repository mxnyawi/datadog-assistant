# Datadog Assistant — 10-second showcase video

A short, design-led promo for the **Datadog Assistant** menu-bar app, built with
[HyperFrames](https://github.com/heygen-com/hyperframes) (HTML → MP4).

**Output:** [`renders/datadog-assistant-demo.mp4`](renders/datadog-assistant-demo.mp4)
— 1920×1080, 30 fps, 10.0 s, H.264.

## The 10 seconds, beat by beat

| Time | Beat | What it shows |
|------|------|---------------|
| 0.0–2.5s | Intro | App lockup — 🐶 *Datadog Assistant — your Datadog alerts, right in the menu bar* |
| 2.5–5.1s | Menu | Menu-bar icon flips 🐶 → ‼️ 2; dropdown reveals monitors grouped by state (incidents / alerting / warning / OK / muted) |
| 5.1–7.1s | Notifications | Native **alert** + **recovery** banners slide in |
| 7.1–8.7s | Critical modal | The can't-miss popup — *Open in Datadog / Dismiss* |
| 8.7–10.0s | Outro | Lockup + repo link |

The UI styling mirrors the real app mockups in [`../docs/mockup.html`](../docs/mockup.html),
scaled to 1080p for video.

## Rebuild / re-render

```bash
# from this directory
npm run check     # lint + validate + inspect (0 errors)
npm run render    # render to MP4
```

Notes for headless / sandboxed environments:

- GSAP is **vendored** at `vendor/gsap.min.js` (referenced locally by `index.html`)
  so rendering works without CDN access.
- Point HyperFrames at an existing Chromium when there's no download access:
  `export HYPERFRAMES_BROWSER_PATH=/path/to/chrome`.

The whole composition is a single self-contained `index.html`: one paused GSAP
timeline registered on `window.__timelines["main"]`, with `data-*` clip timing —
the HyperFrames contract.
