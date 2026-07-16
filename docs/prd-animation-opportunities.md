# PRD — Animation Opportunities: Datadog Assistant

- **Status**: TODO (ready for implementation)
- **Commit**: `0154931` (all `file:line` references are pinned to this commit — if code has drifted, re-locate before editing, and stop if a step no longer matches)
- **Scope**: `swift/Sources/DatadogAssistant` (macOS 13+ menu-bar app) + `website/index.html` (static marketing page)
- **Method**: Emil Kowalski's *find-animation-opportunities* discipline — every item below passed a four-question gate (frequency → purpose → speed budget → function). Rejected candidates are listed at the end **and must stay rejected**; do not "improve" them while in the neighborhood.
- **Audience**: an implementing agent with zero prior context. Every value is spelled out; never approximate or substitute curves/durations.

---

## 1. Product context & motion personality

Datadog Assistant is an on-call ops tool: a 360pt-wide menu-bar panel watched many times a day, whose one emotional promise is alerts that are **"impossible to ignore"** (README). The house motion philosophy is already documented and must be preserved:

- **Restrained, accessibility-first, opt-out.** `docs/migration-review-2026-07-15.md:127` — "an optional subtle pulse on a new alert (respecting Reduce Motion). One person's signal is another's noise."
- Daily-use surfaces get near-imperceptible motion or none; the delight budget is spent **only** on the rare, high-emotion moments (a P1 firing, first-time connection success) and the marketing page.
- Data being *read* (monitor lists mid-incident, sparklines, counts) must never move for style.

**Implication:** this PRD adds very little motion. Its highest-leverage items are (a) giving the app's single most important moment — the P1 modal — physical weight, (b) bridging a handful of teleporting state changes, and (c) closing three Reduce-Motion gaps so the whole app follows its own rule.

## 2. Existing motion vocabulary (extend this — never invent a parallel one)

All shared primitives live in `swift/Sources/DatadogAssistant/Views/Interactions.swift`:

| Primitive | Definition | Values |
| --- | --- | --- |
| `.pressable` (`PressableButtonStyle`) | `Interactions.swift:8-34` | press: `scaleEffect(0.97)` + `opacity(0.85)`, `.easeOut(duration: 0.14)`; scale suppressed under Reduce Motion |
| `.hoverFade(_:)` | `Interactions.swift:39-41` | `.easeOut(duration: 0.12)` keyed on hover |
| `.animatedContent(_:reduceMotion:)` | `Interactions.swift:45-51` | `.spring(response: 0.4, dampingFraction: 0.85)` normally; `.easeOut(duration: 0.2)` under Reduce Motion |
| Panel open fade | `MenuBarController.swift:184-199` | `NSAnimationContext`, `duration 0.14`, `.easeOut`, alpha 0→1; instant under Reduce Motion |
| Menu-bar icon pulse | `MenuBarController.swift:94-102` | alpha dip to 0.25, restore over `0.45s` `.easeInEaseOut`; guarded by `accessibilityDisplayShouldReduceMotion` and pref `pulseOnAlert` |
| Row expand spring | `MonitorRow.swift:37-40` | `.spring(response: 0.3, dampingFraction: 0.8)`; `.easeOut(0.2)` under Reduce Motion |
| Expanded-details transition | `MonitorRow.swift:67` | `.transition(.opacity.combined(with: .move(edge: .top)))` — the only `.transition` in the app today; use it as the exemplar |
| Number morphs | `MonitorRow.swift:137`, `StateCard.swift:30`, `HeroAlertCard.swift:100`, `ResponseStrip.swift:34` | `.contentTransition(.numericText())` |
| Hero live-dot pulse | `HeroAlertCard.swift:52-56` | `.easeInOut(duration: 0.9).repeatForever(autoreverses: true)` (currently NOT Reduce-Motion aware — fixed by A5) |

**House duration/curve palette** (choose from these; do not add new magnitudes without reason): `0.12` hover, `0.14` press/panel, `0.2` reduce-motion ease, springs `(0.3, 0.8)`, `(0.3, 0.85)`, `(0.4, 0.85)`.

**Unused vocabulary this PRD introduces deliberately (nowhere else):** `.symbolEffect(.bounce)` (macOS 14+, availability-gated), CSS `@keyframes`/scroll reveal on the website.

**The Reduce-Motion pattern.** SwiftUI views read `@Environment(\.accessibilityReduceMotion)`; AppKit code reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Reduced motion means *gentler, not zero*: keep opacity fades, drop movement/scale/repetition. Every new animation in this PRD must ship with its reduce-motion branch — treat a missing branch as a review-blocking defect.

---

## 3. Opportunities (gated, ordered by leverage)

| # | Location | Today | Purpose | Frequency | Suggested motion |
| --- | --- | --- | --- | --- | --- |
| A1 | `ModalAlertWindow.swift:36-38, 47-51` | P1 "unmissable popup" appears and vanishes with zero animation | Feedback + preventing a jarring change (the app's flagship moment) | Rare (P1 only) | Window alpha 0→1 over `0.18s` ease-out + content scale `0.98→1.0` spring `(0.35, 0.8)`; exit fade `0.14s`; Reduce Motion → fade only |
| A2 | `RootView.swift:11-15`, `ConnectPromptView` | Setup↔dashboard is a bare `if/else`; connection success has no moment | State indication + delight (first-run success) | Rare / first-time | Cross-fade + subtle scale via `.transition(.opacity.combined(with: .scale(0.98)))` on both branches, driven by `.animatedContent(store.needsSetup, ...)`; brief ✓ beat in the connect flow |
| A3 | `RootView.swift:49-51, 56-57`, `IncidentsSection.swift:7` | Hero card / incidents strip / response strip blink in and out of the dashboard stack | Preventing a jarring change | Occasional (section-level appearance, not per-refresh) | `.transition(.opacity.combined(with: .move(edge: .top)))` per section, riding the existing `animatedContent` spring `(0.4, 0.85)`; Reduce Motion → `.opacity` only |
| A4 | `HeaderView.swift:16-20, 42`, `MonitorRow.swift:86` | Connection dot/label, pin rotation, favorite star all snap | State indication / feedback | Occasional | Dot+label: `.easeOut(0.2)`; pin: spring `(0.3, 0.8)` on the existing 45° rotation; star: `.symbolEffect(.bounce, value:)` gated `#available(macOS 14.0, *)` |
| A5 | `DLQSection.swift:37`, `FooterView.swift` `toggleList()`, `HeroAlertCard.swift:52-56` | Three animation sites skip the app's own Reduce-Motion rule | Accessibility / house-rule compliance | — | Route all three through the `Interactions.swift` pattern; hero pulse becomes a static full-opacity dot under Reduce Motion |
| A6 | `website/index.html` | Feature grid, showcase, steps render static; FAQ `<details>` snaps open; no `prefers-reduced-motion` block | Explanation + delight (marketing page — longer budget allowed) | Rare (visitor first impression) | Scroll-reveal: opacity 0 + `translateY(12px)` → settled, `400ms cubic-bezier(0.23, 1, 0.32, 1)`, 60ms stagger; FAQ height transition; full `prefers-reduced-motion` fallback |

Six items. That is the whole list — resist adding more (see §5).

---

## 4. Detailed specifications

### A1 — Give the P1 modal alert an entrance and exit

- **Severity**: HIGH (highest-leverage item in this PRD)
- **Estimated scope**: 1 file (`swift/Sources/DatadogAssistant/App/ModalAlertWindow.swift`), ~30 lines

**Problem.** The product's defining moment — "a modal popup macOS can't silence for the P1s that can't wait" (website copy) — currently teleports onto screen:

```swift
// ModalAlertWindow.swift:36-38 — current
window?.center()
NSApp.activate(ignoringOtherApps: true)
window?.makeKeyAndOrderFront(nil)
```

and vanishes the same way (`close()`, line 47-51: `window?.orderOut(nil)`). A rare, high-emotion surface with zero physical weight. This is exactly where the delight budget lives: an entrance makes the alert feel like an *event*, and a considered exit prevents the "did it crash?" blink on dismiss.

**Target.**

1. **Window fade-in** — mirror the existing panel-fade exemplar (`MenuBarController.swift:184-199`): set `alphaValue = 0` before `makeKeyAndOrderFront`, then

```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.18
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    window.animator().alphaValue = 1
}
```

Under `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, skip the group and set `alphaValue = 1` directly (same branch shape as `MenuBarController.swift:188`).

2. **Content scale-in** — inside `ModalAlertView`, add a state-driven entrance so the card settles rather than pops. Never start from `scale(0)`; start at `0.98`:

```swift
@State private var appeared = false
@Environment(\.accessibilityReduceMotion) private var reduceMotion
// on the outer VStack (after .frame(width: 380)):
.scaleEffect(appeared || reduceMotion ? 1 : 0.98)
.animation(.spring(response: 0.35, dampingFraction: 0.8), value: appeared)
.onAppear { appeared = true }
```

Note: `show(...)` replaces `contentViewController` on re-fire (line 34), so a *newer alert replacing the content* re-runs `onAppear` — that is desirable (each new P1 gets its beat). The window itself must NOT re-fade if already visible: guard the alpha animation with `if window?.isVisible != true`.

3. **Exit fade** — in `close()`, fade `alphaValue` to 0 over `0.14s` ease-out with `NSAnimationContext` and call `orderOut(nil)` in the completion handler; instant under Reduce Motion. Symmetric family with the panel's own open fade.

3a. The exclamation icon (line 63) may take `.symbolEffect(.bounce, options: .nonRepeating)` behind `#available(macOS 14.0, *)` **and** `!reduceMotion` — one bounce on appear, never repeating. This is optional garnish; skip if it fights the scale-in when previewed.

**Repo conventions to follow.** AppKit alpha animation exemplar: `MenuBarController.swift:184-199`. Reduce-Motion AppKit check exemplar: `MenuBarController.swift:95`. SwiftUI spring values must come from the house palette (§2).

**Steps.**
1. Add the visibility-guarded fade-in to `show(...)`.
2. Add `appeared`/`reduceMotion` state and the scale entrance to `ModalAlertView`.
3. Convert `close()` to fade-out-then-orderOut (keep `dismissWork` cancellation semantics exactly as they are).

**Boundaries.** Do not change window level, collection behavior, the 5-minute auto-dismiss, or the button/keyboard-shortcut wiring. No new dependencies.

**Verification.**
- Mechanical: `cd swift && swift build` succeeds.
- Feel check (use a test alert — Settings has a test-notification path, or temporarily lower the modal threshold): window fades in ~0.18s while the card settles from 98%; Dismiss fades out rather than blinking; firing a second alert while visible swaps content with a small settle but does NOT re-fade the window.
- Toggle System Settings → Accessibility → Display → Reduce Motion: entrance/exit become plain fades (or instant for the window), no scale, no bounce.
- Done when all three observations hold in both motion modes.

### A2 — Bridge setup → dashboard and mark connection success

- **Severity**: MEDIUM
- **Estimated scope**: 2 files (`Views/RootView.swift`, `Views/ConnectPromptView.swift`), ~25 lines

**Problem.** First-run success is invisible. `RootView.swift:11-15`:

```swift
var body: some View {
    if store.needsSetup {
        setupBody
    } else {
        dashboardBody
    }
}
```

The instant credentials land, the entire 360pt panel content teleports from the connect prompt to the dashboard. `ConnectPromptView.connect()` shows a `ProgressView` while busy, then the swap just… happens. A once-per-install, high-emotion moment (it worked! data is flowing!) rendered flat. PARITY.md:113 already flags onboarding as the gap.

**Target.**

1. Animate the root swap. In `RootView.body`, wrap the conditional in a container that animates on `store.needsSetup` and give both branches a transition:

```swift
var body: some View {
    ZStack {
        if store.needsSetup {
            setupBody
                .transition(.opacity)
        } else {
            dashboardBody
                .transition(.opacity.combined(with: .scale(0.98)))
        }
    }
    .animatedContent(store.needsSetup, reduceMotion: reduceMotion)
}
```

(`reduceMotion` is already read at `RootView.swift:8`; `.animatedContent` collapses to `.easeOut(0.2)` under Reduce Motion, and `.scale(0.98)` at 0.2s opacity-dominant reads as a fade — acceptable.) The dashboard *enters* settling from 98%; the setup view exits as a plain fade. Never scale below 0.95.

2. A success beat in `ConnectPromptView`: when `connect()` succeeds (the happy path immediately before the `.reloadCredentials` post at `ConnectPromptView.swift:100-127`), flip a `@State private var succeeded = true` and show `Image(systemName: "checkmark.circle.fill")` in place of the busy `ProgressView` for ~0.4s before the root swap proceeds (delay the notification post with `try? await Task.sleep(for: .milliseconds(400))`). Green (`Theme.ok`), `.symbolEffect(.bounce, options: .nonRepeating)` behind `#available(macOS 14.0, *)` and `!reduceMotion`. Keep total added latency ≤ 400ms — this is a beat, not a ceremony.

**Repo conventions.** Transition exemplar: `MonitorRow.swift:67`. Spring/reduce-motion: `Interactions.swift:45-51`. Color: `Theme.ok`.

**Boundaries.** Do not restructure `setupBody`/`dashboardBody` internals. Do not touch credential logic, error paths (error text stays instant — failures should never wait on animation), or `SnapshotStore`.

**Verification.**
- Mechanical: `swift build`.
- Feel check: from a no-credentials state, paste a valid token → ✓ appears with a single bounce, then the dashboard cross-fades in with a barely perceptible settle. With Reduce Motion: ✓ appears statically, swap is a 0.2s fade. A *failed* connect shows the error with zero added delay.
- Done when success shows the beat and failure path timing is untouched.

### A3 — Section-level enter/exit in the dashboard stack

- **Severity**: MEDIUM
- **Estimated scope**: 1 file (`Views/RootView.swift`), ~6 lines (plus optionally `IncidentsSection.swift`/`ResponseStrip.swift` if the transition is better attached inside)

**Problem.** Whole sections appear and disappear from the monitors tab as data changes: the hero card when a P1/P2 starts or resolves (`RootView.swift:49-51`), the incidents strip when the first incident opens (`IncidentsSection.swift:7` — `if !incidents.isEmpty`), the response strip when stats become available (`ResponseStrip.swift:10`). They have no individual `.transition`, so although the surviving siblings *slide* into place under the global `animatedContent` spring (`RootView.swift:83`), the section itself **pops** in/out at full opacity. A monitor going from healthy to P1 inserts a ~150pt red card instantly — jarring in exactly the moment the user is already stressed.

**Target.** Attach the house transition to each conditional section at its use site in `RootView.dashboardBody`:

```swift
if let hero {
    HeroAlertCard(monitor: hero)
        .transition(reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top)))
}
```

Same modifier on `IncidentsSection(snapshot:)` and `ResponseStrip(stats:)` calls (`RootView.swift:56-57`). No new `withAnimation` — the existing `.animatedContent(snapshot, ...)` at `RootView.swift:83` already provides the spring `(0.4, 0.85)` that drives these transitions.

**Boundaries.** Exactly these three sections. Do NOT add transitions to `StateSection`, `FilterBar`, `ClusterChips`, `ActiveMonitorsSection`, or per-row `ForEach` content — rows are data being read mid-incident and were explicitly rejected (§5, R7). Do not touch the global `animatedContent` values.

**Verification.**
- Mechanical: `swift build`.
- Feel check (sample-data mode makes this easy — `snapshot.sampleData` exists): when the hero card condition flips, the card fades + slides in from the top edge under the spring instead of popping; on resolve it exits the same way (symmetric paths). Reduce Motion: pure cross-fade.
- Done when insertion and removal are visibly bridged and nothing else in the stack changed behavior.

### A4 — Micro state-change feedback (dot, pin, star)

- **Severity**: LOW
- **Estimated scope**: 2 files (`Views/Components/HeaderView.swift`, `Views/Components/MonitorRow.swift`), ~10 lines

**Problem.** Three tiny state indicators snap:

```swift
// HeaderView.swift:15-18 — current: instant green↔gray
Circle()
    .fill(snapshot.connected ? Theme.ok : Theme.muted)
```

```swift
// HeaderView.swift:42 — current: pin snaps 45°↔0° (prefs.pinned isn't part of
// `snapshot`, so the global spring never covers it)
.rotationEffect(.degrees(prefs.pinned ? 0 : 45))
```

```swift
// MonitorRow.swift:86 — current: star↔star.fill swaps with only the .pressable scale
Image(systemName: isFavorite ? "star.fill" : "star")
```

**Target.**
1. Connection dot + "Reconnecting…" label: add `.animation(.easeOut(duration: 0.2), value: snapshot.connected)` on the `HStack` in `HeaderView` (colors cross-fade; the text swap rides it).
2. Pin: `.animation(.spring(response: 0.3, dampingFraction: 0.8), value: prefs.pinned)` on the pin `Image` — but suppressed under Reduce Motion: read `@Environment(\.accessibilityReduceMotion)` in `HeaderView` and pass `nil` as the animation when set (`.animation(reduceMotion ? nil : .spring(...), value: prefs.pinned)`).
3. Star: on the star `Image` add

```swift
// inside MonitorRow (already has `reduceMotion` at line 18)
.symbolEffectIfAvailable(bounceOn: isFavorite)  // or inline:
// if #available(macOS 14.0, *) { view.symbolEffect(.bounce, options: .nonRepeating, value: isFavorite) }
```

Use an availability-gated `@ViewBuilder` helper (place it in `Interactions.swift` so future call-sites share it), no-op on macOS 13 and under Reduce Motion. Bounce only on *favoriting*; if the API bounces on both directions, that is acceptable — do not build extra state to suppress the un-favorite bounce.

**Boundaries.** Nothing else in HeaderView (the refresh button stays exactly as is — see rejection R4). No new preference toggles.

**Verification.** `swift build`; toggling pin springs through the 45°; dot fades over 0.2s on simulated disconnect; star gives one small bounce on macOS 14+, silently does nothing on macOS 13. All three inert (color fade only) under Reduce Motion.

### A5 — Reduce-Motion hygiene: three non-compliant sites

- **Severity**: MEDIUM (accessibility; also the cheapest item here)
- **Estimated scope**: 3 files, ~12 lines

**Problem.** The app's documented rule (§1) is broken in three places:

1. `DLQSection.swift:37` — `withAnimation { showHealthy.toggle() }` uses the default animation, ignores Reduce Motion, and the revealed `InsetCard` has no `.transition`.
2. `FooterView.swift` (`toggleList()`) — `withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = ... }` unconditionally.
3. `HeroAlertCard.swift:52-56` — the live-dot `.repeatForever` pulse runs regardless of Reduce Motion (contrast `MenuBarController.swift:95`, which guards its pulse).

**Target.**
1. `DLQSection`: read `@Environment(\.accessibilityReduceMotion)`; use the exact `MonitorRow.swift:37-40` pattern — `withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.8))` — and add `.transition(.opacity.combined(with: .move(edge: .top)))` to the healthy `InsetCard` (mirror of `MonitorRow.swift:67`).
2. `FooterView`: same environment read; `withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.85))`.
3. `HeroAlertCard`: read `@Environment(\.accessibilityReduceMotion)`; when set, do not start the pulse — dot stays at full opacity: `.opacity(pulsing && !reduceMotion ? 0.35 : 1.0)` and `.animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)`.

**Boundaries.** Values stay exactly as today for the non-reduced path; this item changes *only* the reduced path (plus the missing DLQ transition).

**Verification.** `swift build`; with Reduce Motion on: DLQ disclosure fades (no slide/spring), tab toggle fades, hero dot is static at full opacity. With it off: behavior is pixel-identical to before except the DLQ card now enters with the house transition.

### A6 — Website motion pass (scroll reveal, FAQ, reduced-motion)

- **Severity**: MEDIUM
- **Estimated scope**: 1 file (`website/index.html`), ~60 lines of CSS + ~10 lines of JS

**Problem.** The marketing page — the one surface where explanation/delight motion is fully licensed — has almost none. `website/index.html`: the only transition is `.btn{transition:background .15s, border-color .15s, color .15s}` (line 33). The feature grid ("Built for on-call"), the four-screenshot showcase, and the four install steps all render statically; the FAQ `<details>` snaps open with an instant `+`→`−` marker swap (lines 119-126); and there is **no `prefers-reduced-motion` handling anywhere**.

**Target.** All inline in the existing `<style>`/end-of-body, no libraries, no external requests.

1. **Easing token** — add to `:root`: `--ease-out: cubic-bezier(0.23, 1, 0.32, 1);`

2. **Scroll reveal** on `.cell`, `.frame`, and `.tut` elements (the grid cells, showcase figures, tutorial steps):

```css
.reveal { opacity: 0; transform: translateY(12px);
  transition: opacity 400ms var(--ease-out), transform 400ms var(--ease-out); }
.reveal.in { opacity: 1; transform: none; }
/* stagger within a group — cap at 3 steps so late items never feel laggy */
.reveal:nth-child(2) { transition-delay: 60ms; }
.reveal:nth-child(3) { transition-delay: 120ms; }
```

```html
<script>
  const io = new IntersectionObserver((es) => es.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
  }), { rootMargin: '0px 0px -10% 0px' });
  document.querySelectorAll('.grid .cell, .showcase .frame, .tutorial .tut')
    .forEach(el => { el.classList.add('reveal'); io.observe(el); });
</script>
```

Adding `.reveal` from JS means no-JS visitors (and crawlers) see everything at full opacity — never gate initial visibility on script in the markup itself.

3. **FAQ accordion** — progressive enhancement via the modern details-content transition (browsers without support keep today's instant open, which is fine):

```css
details::details-content {
  block-size: 0; overflow: hidden;
  transition: block-size 250ms var(--ease-out), content-visibility 250ms allow-discrete;
}
details[open]::details-content { block-size: auto; }
@supports (interpolate-size: allow-keywords) { :root { interpolate-size: allow-keywords; } }
summary::after { transition: rotate 200ms var(--ease-out); }
details[open] summary::after { rotate: 45deg; }
/* swap the +/− content trick for a single "+" that rotates 45° into "×"…
   keep "−" if the rotate reads worse — check both */
```

(250ms is inside the dropdown budget of 150–250ms; the `block-size` transition only works where `interpolate-size` is supported — acceptable.)

4. **Reduced motion** — mandatory block:

```css
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  .reveal { opacity: 1; transform: none; transition: opacity 200ms ease; }
  details::details-content, summary::after { transition: none; }
}
```

**Boundaries.** No hero letter-by-letter effects, no parallax, no mouse-tracking, no animation on nav or buttons beyond the existing color transitions, no external fonts/scripts (keep the page dependency-free). Do not restructure the HTML sections; only add classes/observer.

**Verification.**
- Open the page locally; scroll: grid cells / screenshots / steps fade-rise in once, ~400ms, 60ms cascade, never re-trigger.
- Disable JS: all content fully visible, no blank sections.
- FAQ in Chrome/Safari-current: opens with a smooth height transition; in an older browser: opens instantly (no breakage).
- Emulate `prefers-reduced-motion: reduce` (DevTools → Rendering): reveals become simple fades already-visible, marker rotation off, smooth-scroll off.
- Lighthouse/scroll performance: transitions animate only `opacity`/`transform` (the FAQ `block-size` is the sanctioned exception, user-initiated and small).

---

## 5. Rejected candidates — DO NOT IMPLEMENT

These were considered and deliberately excluded. They are recorded so a future pass doesn't re-litigate them; implementing any of these is out of scope and counter to the product's motion philosophy.

- **R1 — Command palette (⌘K) open/close animation.** `RootView.swift:85-89` renders `CommandPalette` with no transition. **Rejected: keyboard-initiated. Never animate** — animation makes a 100+/day power-user surface feel slow and disconnected (the Raycast rule). The instant appearance is correct as-is.
- **R2 — Panel close fade** (`MenuBarController.swift:205`, instant `orderOut`). **Rejected: frequency.** The panel toggles many times a day; native macOS menus close instantly, and the asymmetry (0.14s open fade, instant close) is the platform-correct feel.
- **R3 — Menu-bar badge digit ticker** (`MenuBarController.swift:80-89`). **Rejected: frequency + periphery.** The count is permanently in the user's peripheral vision; a rolling digit would be ambient motion at the highest-frequency tier. The existing opt-out pulse already covers "something changed."
- **R4 — Spinning refresh icon** (`HeaderView.swift:50-57`). **Rejected: frequency.** Auto-refresh fires every 15–60s; a rotating glyph in a pinned panel is perpetual motion. The current opacity dim is the right amount of signal.
- **R5 — TabStrip sliding selection pill** (`matchedGeometryEffect`, `TabStrip.swift:73-76`). **Rejected: frequency.** Tab switches happen tens of times a day and are keyboard-reachable (⌘F); selection must read as instant. The `.pressable` scale is sufficient feedback.
- **R6 — Sparkline draw-in / scrub smoothing** (`Sparkline.swift:68-96`). **Rejected: function.** This is threshold data an on-call engineer is *reading* during an incident; the cursor snapping exactly to the pointer is a feature, and a draw-in animation would delay the information.
- **R7 — Per-row enter/exit/reorder transitions in monitor lists** (`ActiveMonitorsSection.swift:25`, `MonitorListSection.swift:116`). **Rejected: function + frequency.** Rows change under the user every refresh cycle while they scan for a specific monitor; individual row motion during reading hinders. The global snapshot spring already keeps the layout continuous.

## 6. Verdict & execution order

This interface is already close to right: it has a coherent press/hover/spring vocabulary, `numericText` on every count, and a documented restraint philosophy — what's missing is concentrated at the extremes. The single highest-leverage change is **A1**: the P1 modal is the product's whole reason to exist and today it's the least physical thing in the app. A5 is the cheapest and should ride along in the same PR-sized change. Recommended order: **A5 → A1 → A2 → A3 → A4 → A6** (hygiene first since later items copy its pattern; website last since it's an independent surface). Each item is independently shippable; none depends on another beyond the shared `Interactions.swift` helper introduced in A4.

Total added motion: six touchpoints, four of which fire rarely. If an implementation review finds any item making a daily surface feel slower, the correct fix is to delete that item, not to tune it.
