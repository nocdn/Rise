# Motion in Rise for iOS: Summarise and the tab switcher

This is everything learned while building the iOS app's Summarise interaction, a remake of
Arc Search's, and then carrying its motion over to the tab switcher. It covers what was measured,
what was tried and thrown away, the numbers in use now, the physics behind them, the performance
lessons, the tools for checking motion, and Bartosz's preferences, which drove almost every
decision. Read it before touching either animation.

The code it describes:

- `Apps/iOS/Rise/Summarise.swift`: `SummariseMotion` (every constant), `SummariseSpring` (the spring
  maths), `SummariseView` (the scene), the summary's model request and its SwiftUI text.
- `Apps/iOS/Rise/TabSwitcher.swift`: `TabSwitcherView`, which flies its moving page on
  the shared spring maths, with its own tab-specific tuning.
- `Apps/iOS/Rise/BrowserViewController.swift`: the gestures (the pinch, the swipe up the bar), and
  how both scenes sit over the page.
- `Apps/iOS/Rise/SummariseLog.swift` and `scripts/summarise-log.py`: the on-device frame log.
- `Apps/iOS/Rise/SummariseReplay.swift` (DEBUG only): scripted replays and timing runs.
- `Playgrounds/summarise.html` and `Playgrounds/summarise-reference.mp4`: the web playground with
  dials, and the Arc recording it was measured from.

The deck uses the same `SummariseSpring` maths with separate `TabDeckMotion` constants.
Changing Summarise must not silently change the tab switcher.

---

## 1. Bartosz's preferences

These came out of many rounds of trying things on the phone. Follow them by default.

### How he works

- **He tunes by feel, on the device, and says so in plain words.** Expect feedback like "it's a
  bit hitchy", "make it a tiny bit slower", "it kinda skips the animation". Turn that into
  numbers, change one thing at a time, and say what each change will feel like.
- **Playground first for big new motion.** For Summarise he asked for a web playground with dials
  before anything went native. He scrubbed it against the reference video, tuned dials, and pasted
  back only what he changed (Copy values gave `{"barExit": 0.18, "contentsOut": 0.1}`). Then the
  port had to match the playground exactly.
- **Verify before claiming.** He wants changes checked (replays, frame strips, device timing) and
  the result reported honestly, including what couldn't be checked. Haptics and how a gesture
  feels in the hand can only be judged on the phone; say so.
- **Rebuild and relaunch on the iPhone after every change** with
  `./scripts/restart.sh --ios --device A0008B8F-939F-5363-85C4-9027E8AA261D`.
- **Commits only when asked**, straight to `main`, as the repo's history does, and pushed when he
  says "push". Never touch the desktop Chromium migration branch (`origin/chromium-engine`).

### What he likes in motion

- **Physical and continuous, never on rails.** "It's not like a rigid linear line that it always
  follows. It goes from wherever I choose to pinch it." Things start from wherever they are, carry
  on at the speed they were going, and curve round to where they belong.
- **Follows the fingers exactly.** The spot under the fingers stays under them. A hard pinch or
  flick should feel harder: it shrinks more and dips past its resting size before springing back.
  A gentle one glides.
- **Momentum through the release.** After letting go, the page keeps going the way the fingers
  were going "for a tiny bit", then changes direction smoothly. Sharp direction changes read as
  wrong.
- **Interruptible everywhere, as in Safari.** Any move can be caught or turned around partway: a
  pinch catches the card as it grows back; Tabs again, a tap on the landing card, or a swipe up
  catches the tab page. He noticed straight away when the reopening Summarise couldn't be pinched
  again for a second or two.
- **Slightly slower and softer rather than snappy.** He twice asked for the pinching and
  placing to be "a tiny bit slower", and for the flight from a far corner to be "smoother" as it
  changes direction.
- **120 Hz, no hitches.** His phone is ProMotion and he notices 60 Hz and single dropped frames,
  especially at the start of a gesture and at release.
- **Rounded corners early.** At the start of a pinch the corners should round almost at once, and
  generously.
- **Gradual progress.** A small pinch should move the page only a little; it shouldn't take "a
  very small amount to make it move quickly".
- **Text materialises with the motion it belongs to.** In the horizontal Arc-style deck
  requested on 15 October, titles sit above their cards. Older tabs and their titles rise as
  one from the bottom-left stack; the active page's own title rides above it as it shrinks.
  Only the centred card shows title text; neighbouring favicons remain visible.
  There is no delayed grid fade after the page has landed. Going back, the other cards fade
  quickly. The incoming cards fly smoothly into place without any bounce. This supersedes
  the earlier two-column grid's stationary-title behaviour.
- **Plain, immediate backgrounds.** The tab switcher sits on a solid grey from the first frame,
  not a blur of the page fading in.
- **Only what moves should move.** When the summary closes, only the summary text sinks back; the
  backdrop stays put.
- **Scroll everything together.** The card and the summary scroll as one page, not a text box.

### What he removed (don't bring these back unasked)

- **The 3D fold** in the pinch (built, flipped to a mountain fold at his request, then dropped:
  "i dont like the folding"). The pinch now takes the same path as Summarise in More, under the
  fingers.
- **The unfold** of the page below the card on close (built, sped up twice, then dropped once the
  fold was gone: "there's no need for it to unfold").
- **Haptics during the pinch** and **a click at the commit threshold** (he asked for them, tried
  them, then: "no haptics during the pinch, and no click").
- **The page title above the card** (added, made to tilt with the card, weight raised from regular
  to medium to semibold, colour to 70% black, then removed: "I already know what it is").
- **"Summarising for you…"**, the footer ("Summarised for you by Rise" and its X), and the
  backdrop shrinking on close.
- **Titles on More's four tiles** (symbols only now, tiles 85% as tall as wide).

### Haptics he wants

- **While summarising:** the same soft hum as holding New Page (continuous, intensity 0.22,
  sharpness 0, looped). It starts when the pinch commits or Summarise is tapped.
- **At the reveal:** "one fairly short, strong but dull (not the sharp) haptic" (transient,
  intensity 1, sharpness 0.12). It ends the hum.
- **Nothing while pinching.**
- **Nothing when releasing a swipe into the tab switcher.** Its rigid commit impact was removed
  after he asked for a silent release.

---

## 2. The physics

### Springs

Every spring is `SummariseSpring(ω, ζ, v₀)`: angular frequency in rad/s, damping ratio, and a
starting velocity in whole distances per second, as in the playground. 2π/ω is roughly the
perceived duration, and 1 − ζ the bounce.

It's used two ways:

- **Progress** (`spring(t)`, from 0 to 1): for moves that start from rest, or whose start speed
  is part of the design (`v₀`). Every value is a `lerp(from, to, progress)`.
- **Released** (`spring.value(from:to:velocity:at:)`): a physical spring started at `from` and
  moving at `velocity` in the value's own units per second. Use this whenever something is let go
  or turned around, so it carries on at the speed it had. Its closed form (ζ < 1):
  `to + e^(−ζωt)·(d·cos(ω_d t) + (v + ζωd)/ω_d · sin(ω_d t))`, with `d = from − to` and
  `ω_d = ω√(1−ζ²)`; for ζ = 1, `to + e^(−ωt)·(d + (v + ωd)t)`.

**Separate springs for size and place.** This is the key to a smooth curved path. A release gives
the scale and the position their own springs, each starting at the velocity the fingers left it.
Position on a softer spring than size means the page reaches its size first and then glides into
place along a curve set by where it was going. A single spring for everything gives a straight,
abrupt path.

### The springs in use

| Constant | (ω, ζ, v₀) | ≈ 2π/ω | Used for |
|---|---|---|---|
| `releaseScale` | (11, 0.8) | 0.57 s | Size after a pinch or swipe is let go. Soft enough for a hard pinch to dip well under the card. |
| `releaseMove` | (9, 0.9) | 0.70 s | Place after release. About half a second from across the screen, peaking around 1000 pt/s. |
| `placeCrop` | (20, 0.9) | 0.31 s | Crop, corners and tilt settling after release. |
| `cancel` | (2π/0.36, 1) | 0.36 s | Springing back to the page from a short pinch or swipe, carrying its speed. |
| `close` | (9.5, 1, 11.5) | 0.66 s | Card growing back into the page. Matches Arc: 47% at +0.05 s, 86% at +0.16 s, 96% at +0.25 s. Settles by 7/(ωζ) ≈ 0.74 s. |
| `menuShrink` | (9.5, 0.95, 7) | 0.66 s | Summarise in More: the page shrinking into the card from rest. |
| `menuCrop` | (24.5, 0.9) | 0.26 s | The crop on that path. |
| `reveal` | (13, 1, 1) | 0.48 s | The card growing a little as the summary appears. |
| `grabBlend` | (2π/0.3, 1) | 0.30 s | A caught card's crop, corners and tilt coming to the pinch's own. |
| Bar return | ω = 2π/0.27, ζ = 1 − 0.25 | 0.27 s | The bottom bar springing back, bounce 0.25. |

How they got here:

- **The release spring went from (15, 0.8)** (about 0.3 s, Safari's settle) to separate scale
  (11, 0.8) and move (9, 0.9). He asked for slower placing, a smoother turn from a far corner, and
  a deeper dip on hard pinches.
- **The unfold** went from ω 9 to 16 with v₀ 8 in the playground and ω 18 in the app before it was
  removed.

### Measuring the fingers' speed

- **Sampling:** the page's own `(scale, x, top)` are sampled at each touch event, on the touch
  clock (`CACurrentMediaTime()` when the event is handled), not the animation clock. The
  animation clock runs a frame ahead and bunched the samples, giving spiky speeds and a jolt at
  release.
- **Speed:** taken over the last `velocityWindow` = 0.06 s, from the first sample to the last;
  0.1 s blunted quick flicks. It needs at least 8 ms of samples.
- **Clamps:** `maxScaleSpeed` 5 per second and `maxMoveSpeed` 4000 pt/s, which also caps the
  overshoot.
- **Dip on a hard pinch:** with these values it bottoms out around 0.28–0.38 of the page's size
  before growing to the card's 0.526. With the old (15, 0.8) and a cap of 4 it was 0.36–0.46.

### Following the fingers (the anchor model)

This comes from Safari's pinch into its tabs. When the gesture takes over, the point on the page
under the fingers becomes the **anchor**. At scale `s`, the page is placed so the anchor stays
under the fingers' centroid:

```
x      = centroid.x − (anchor.x − width/2)·s − width/2        (offset of the page's middle)
middle = centroid.y − (anchor.y − cropTop − cropH/2)·s
top    = middle − cropH·s·cos(tilt)/2
```

As it shrinks, the page takes on the card's look by `k = clamp((1 − s)/(1 − loadScale))^1.3`:

- **Crop:** the top crops to `cropTop` 47 pt, and the height goes to `cardHeight`.
- **Tilt:** it tips to `restTilt` −6°.
- **Corners:** they round to `pinchRadius` 40 pt within the first 5% of the way (`pinchRounding`),
  then ease to `cardRadius` 15.

The 1.3 power ("pinchEasing") is what made progress gradual, as he asked.

**Rubber banding past the limits.** Below `pinchMinScale` 0.3 the scale gives exponentially:
`0.3·e^(−(0.3 − f)/0.3)`. Above 1 it approaches `pinchMaxScale` 1.06.

**Committing.** It summarises if let go below `commitScale` 0.85 while not growing faster than
0.6 per second, or while shrinking faster than `commitSpeed` 0.6 per second. Otherwise it springs
back to the page on `cancel`, carrying its speed.

**Interrupting a move.** To catch something mid-flight, read where it is, and how fast it's
going if the new move needs it, then start the new move from there. The tab switcher's flight
gets its speed by finite difference over 1/240 s. Never restart from a fixed pose.

---

## 3. Summarise, phase by phase

### Starting

- **Pinch:** a `UIPinchGestureRecognizer` on the page's container, recognised alongside WebKit's.
  - **Taking over:** only when the page is at its smallest zoom and the fingers have closed below
    0.99. Pinching to zoom in still works.
  - **When:** the take-over happens on that first move, so the first frame is already under the
    fingers.
  - **Inputs:** the centroid updates only while two fingers are down. The anchor is where the
    pinch began.
- **When Summarise takes the pinch:**
  - `bouncesZoom` goes off.
  - WebKit's own pinch and pan recognisers are turned off and on again to end them (they moved the
    page underneath and cost frames).
  - The page's scroll offset and zoom are saved, and put back before the real page shows again.
- **Summarise in More:** the panel goes at once, and the page shrinks to the card on `menuShrink`
  and `menuCrop` from rest.

### The card while the model works

**Place:**
- **Loading:** `loadScale` 0.526 of the screen width, top at `loadTop` 149 pt.
- **Shape:** aspect `cardAspect` 0.975 (height ÷ width); the crop shows the page from 47 pt down.
- **Corners and tilt:** `cardRadius` 15 (unscaled), `restTilt` −6° (top towards you), perspective
  2000.

**Shadow:** two layers:
- wide: radius 17, offset 10;
- near: radius 1.5, offset 1, at 0.8 of the wide one's strength.

Both use Rise's charcoal (#343232) and a `shadowPath`. Their strength is `shadow` 0.16 ×
`(1 − s)/(1 − revealScale)`, so the shadow comes in as the page leaves the screen's edges.

**Back card:** a grey (#C7C7CB) card peeks `backPeek` 12 pt above, inset `backInset` 6 pt. It
fades in `backDelay` 0.38 s after the card starts settling, over `backDuration` 0.2 s.

**Swing:**
- **Motion:** period `swingPeriod` 2.04 s, tilt ±2.1°, sway ±6.7 pt, and a 2 pt bob at twice the
  frequency (lowest in the middle).
- **Formulas:** `x = 6.7·sin φ·dir`, `rz = 2.1·sin φ·dir`, `y = 2·cos 2φ`.
- **Direction:** random per run.
- **Ending:** it dies away on the reveal spring after the reveal, and on the close spring when
  closing.

**Bottom bar:**
- **Leaving:** it slides off as the page takes off (on release, or at once from More). It
  uses the background glows' quadratic ease-out (`1 − (1 − k)²`) over `barExit` 0.18 s,
  moving by its height + 4. It starts promptly and slows throughout the exit; Bartosz asked
  to replace the previous accelerating `k²` curve on 16 October.
- **Coming back:** it springs back as the card grows back, with response 0.27 s and bounce 0.25.
  Arc's bar actually leaves in 0.07 s; he chose 0.18.
- **Background coverage:** a non-interactive sibling continues the bar's opaque background
  down to the screen edge, behind the bar and above Summarise. It follows the existing
  per-frame transform with a one-point overlap, covering the upward rebound without changing
  the bar's bounds, clipping, spring, timing or bounce.

**Status bar:** dark over the backdrop. It counts as over the page while the card's top is above
20 pt, and again 0.15 s into the close.

**The request:**
- **Timing:** it waits `requestDelay` 0.35 s after the commit, until the card has about landed,
  because reading the page's text from WebKit costs about a frame.
- **Model:** the shared OpenRouter model, asked for JSON `{overview, sections[{symbol, heading,
  text}]}` with three to five sections. Unknown SF Symbols fall back to a fixed set.

### The backdrop

- **Palette:** Bartosz asked for Rise's app icon colours, with a subtler background while loading
  and after the reveal. The palette is sampled from `Assets/AppIcon/Rise.icon/Assets/Rise.png`.
- **Wash:** a 100° linear gradient #FFF8EC → #F1FCFB → #F9F4FE (cream, mint and lilac softened
  towards white), always light, even in dark mode. It lightens towards the bottom with #F9FAFD
  from 68% down.
- **Glows:** a cool one (460 pt; mint inner (197, 242, 239), blue outer (206, 231, 251)) and a
  warm one (480 pt; cream inner (254, 234, 202), blush outer (254, 208, 232)). Bartosz asked for
  slightly larger orbs, allowing them to overlap; these are about 20% wider than the original
  380/400 pt sizes. Their baked-in opacity is 0.55, keeping both backgrounds gentle.
  - **Shape:** elliptical (0.85 tall), radial stops at 0, 0.28, 0.62 and 1, blurred σ 40.
  - **Pre-rendered:** drawn once at launch (`prepareGlows`), because blurring them at the start
    stalled frames.
- **Orbit:** they circle each other every `orbitPeriod` 4 s:
  - cool at `(0.5 + 0.34 cos a)·W, (0.41 + 0.22 sin a)·H`;
  - warm opposite at `(0.5 + 0.31 cos(a+π))·W, (0.44 + 0.11 sin(a+π))·H`.
- **After the reveal:** the orbit eases (cubic) to a stop on the left over `settle` 1.8 s. The cool
  glow dims to `coolGlowRest` 0.25 and the warm one fades out over `warmGlowFade` 1.1 s.
- The original Arc wash (#D8D4F5 → #E9D7EE → #FBDAE1), purple/pink glows and violet shadows were
  replaced visually, and the glows enlarged at Bartosz's request; paths and timings remain as measured.

### The reveal

- **Timing:** the summary arrives at a random time, but the reveal waits for the swing to pass
  its middle (every half period, 1.02 s), unless it passed within `syncTolerance` 0.12 s. Arc did
  this in both recorded runs.
- **The card:** it grows to `revealScale` 0.659, with its top at 134 pt, on the `reveal` spring;
  the swing dies away.
- **Haptics:** the hum stops and the dull thud plays.
- **The text:** each block (the overview, then each section) starts `textDelay` 0.12 s +
  `stagger` 0.08 s × its index. Its opacity is `1 − e^(−t/0.12)` and its blur `20·e^(−t/0.15)`.
  The blur is dropped below 0.05.
- **Typography:**
  - Body: 17 pt system on 22 pt lines, #1C1C1E at 85%.
  - Headings: semibold 17 at 90%.
  - Symbols: white bold 13 pt in a 27 pt circle of (42, 48, 255).
  - Spacing: 24 pt side padding, 30 pt after the overview, 22 between sections, 64 at the bottom.
  - Placement: the first paragraph sits `textGap` 38 pt under the card (26 in Arc and the
    playground; he asked for more).
- **Scrolling:** everything (card and summary) scrolls together over the fixed backdrop.

### Closing (tapping the card)

- **The card:** every key goes back to the page on the `close` spring: scale 1, x 0, top 0, crop
  0, full height, corners 0, tilt 0. There's no unfold; it simply uncrops as it grows.
- **The summary:** it fades out over `contentsOut` 0.1 s. It also sinks back by `closeRecede` 10%,
  scaled about the middle of the screen. Only the text does this; the backdrop stays.
- **Other parts:** the shadow fades over 0.2 s, and the bar springs back.
- **Scrolling:** a scrolled summary first folds its scroll into the card's position, so nothing
  jumps.
- **The end:** it's done at 7/(ωζ) ≈ 0.74 s. Then the page's saved scroll and zoom are restored,
  and the overlay is removed in the same frame.
- **Touches:** while closing (and while springing back from a short pinch), the overlay lets
  touches through to the page (`hitTest` returns nil), so a pinch can start on it.
- **Catching it again** (`grab(at:)`):
  - **Anchor:** taken from where the card is now. The fingers' scale multiplies the card's
    current scale.
  - **Look:** the gap between its crop, corners and tilt and the pinch's own for that size fades
    on `grabBlend`, re-applied every frame even while the fingers rest.
  - **Continuity:** the glows carry on from their angle, and the swing stops.
  - **Summary:** if it had one, it isn't asked for again. Let go, it shows again `reshow` 0.5 s
    after release, at the next swing middle. A failed or missing summary is asked for again.

---

## 4. The horizontal tab switcher (15 October 2026)

Bartosz supplied `ScreenRecording_10-15-2026 19-51-35_1.MP4` and asked to replace the
previous two-column Safari-style grid with Arc Search's overlapping horizontal deck.
The reference is 1180 × 2556, approximately 59.94 fps, 16.76 s long. Frame strips and
full-size samples live in the ignored `build/arc-switcher-reference` folder.

### Measured reference

- The first button entry starts near 0.89 s; the page moves towards the right, while older
  cards rise out of the toolbar stack near the lower left. Most movement finishes in
  0.3–0.4 s. The second entry at about 2.77 s repeats that path.
- Settled cards are approximately 70% of screen width. Their height is approximately
  70% of the screen below the status strip, placing their top near 19% and bottom near
  84% of screen height. This preserves the page's proportions instead of squashing it.
- The most recent active page becomes the right-hand card; the preceding tab is in front
  of the deck. Older cards compress behind its left edge, dim slightly, and overlap.
  There is no rotation or 3D tilt once settled.
- Horizontal swipes bring each card forward, with momentum and snapping. Favicons and
  truncated titles sit above each card. Near 12 s, swiping a card upwards closes it and
  lets the remaining cards settle into the gap.
- These are measurements of the supplied video, not a claim that Arc's private spring
  constants are known. Rise uses the same geometry and comparable timing with its own
  subtle spring response.

### Geometry and order

`TabDeckLayout.swift` owns the geometry. Native horizontal `UIScrollView` movement
supplies tracking, rubber banding and deceleration; the deck lays out its visible cards
from the fractional scroll position. The next card is 57% of a screen width to the right;
older cards compress into the left stack, reducing by 2% per step left of focus, capped
at 8%, shrinking equally at the top and bottom. The centred card and every card to its
right remain at full size; moving farther right must never shrink a card. Left-side pages
also gain a black overlay continuously with depth: 14% per step, capped at 36%. Centred
and right-side pages remain undimmed. Captions align
with the page’s left edge. Only the centred card shows its title text: it fades out
before the next title fades in, while neighbouring favicons remain visible. Hidden cards
outside the nearby stack do not lay out every frame, and slot lookup is constant time.

The switcher retains a local most-recently-used display order by tab identity, with the
active page last. It never reorders the browser's shared tab list or changes selection
merely because someone swipes through previews. It opens focused on the preceding tab,
leaving the current page visible on the right; a single tab is centred.

Cards have 22-point continuous corners. Their subtle shadow retains opacity 0.10,
radius 6 pt and a 2 pt downward offset, using an explicit rounded path. The moving page
shares bounds, position, corner-path and opacity keyframes with its shadow, so the shadow
forms during movement and hands over at landing. Existing small light close buttons
remain available alongside swipe-to-close; the last tab cannot be removed. An upward
close keeps the whole tab opaque under the finger and throughout its offscreen flight.
`TabDeckDismissal` captures the displayed cards when the drag begins. The tab behind the
focused one moves right, grows to full size and loses its depth shading as the finger
goes up. Progress is `rise / (rise + 0.22 × cell height)`, so even a short drag starts
moving its neighbour and reversing the finger reverses that progress. Closing the first
card instead pulls its successor left. Cancelling springs the survivors back to their
original layout. Release carries the drag's speed into a 0.36-second spring with 0.06
bounce, matching the app's soft settles; this does not change the bounce-free entrance.

The discarded view is removed offscreen, without a second animation back towards the
deck. The release spring already runs while that tab flies away, and deleting the tab
does not restart it. Content offset and viewport anchoring update together so shrinking
the scroll range cannot shift the deck abruptly. The reflow commits before live-page
WebKit work; a new close or horizontal swipe can catch its displayed pose and size. The
X button retains its separate small shrink/fade. Tab and Close
remain separate VoiceOver targets, with horizontal accessibility scrolling and a Close
Tab custom action.

### Springs and entry

Tab-specific values are in `TabDeckMotion`, independent of Summarise:

| Phase | Angular frequency, damping, initial progress velocity |
|---|---|
| Button size | (26, 1, 8) |
| Button position | (25, 1, 9) |
| Crop and corners | (28, 1, 0) |
| Older tabs rising | (22, 1, 0), at most 48 ms of depth delay |
| Swipe release size | (18, 0.86, 0), with the finger's measured velocity |
| Swipe release position | (16, 0.92, 0), with the finger's measured velocity |
| Opening a settled card | (21, 0.96, 7) |
| Cancellation/reversal | (22, 1, 0), carrying the current velocity |

The current page uses a quick `snapshotView` replica. Its flight commits before drawing
its saved bitmap. `TabDeckEntrance` then commits the other tabs' position, transform,
rounded corners and shadow paths before that deferred bitmap work starts. They rise from
18% of their resting size near the toolbar's Tabs button, gently fanned, with captions
already attached to them. Entry springs are critically damped: the cards approach their
positions and size without overshooting or bouncing. The stack’s 0.46-second keyframes
normalise the spring’s final sample to its resting pose, avoiding a small endpoint snap.
Most movement finishes within 0.3 seconds. The deck background is opaque from the first
frame; no global fade delays the tabs until the current page has finished moving.

Every explicit keyframe animation requests 80–120 Hz, preferring 120. A rate-holding
display link covers finger tracking, flights, horizontal scrolling, and close gestures.
During flights, no page/layout/snapshot work runs once per animation frame on the main
thread. Finger-driven horizontal scrolling lays out only the nearby visible cards. Both resting
cards and the page still in flight belong to the native scroll view’s gesture ancestry.
The close pan uses a separate gesture delegate: UIKit also calls UIView’s similarly named
gesture-admission method before movement has supplied velocity. A vertical-only override
on the card can reject the horizontal scroll pan. The card is a UIControl with explicit
8-point tap tolerance, rather than a UIButton with competing selection recognizers.
Leaving that tolerance permanently cancels activation for the touch, even if it returns
to its starting point; ordinary taps retain the 97% press scale and quick opening flight.

### Corners and interruption: do not regress

- **The full page starts with the device's own corner radius, all four corners, in its
  very first moving frame.** It eases towards the card's radius. Older cards likewise
  start with generous device-like rounding before they grow out of the small stack.
- A bottom-bar swipe uses the same early rounding and finger anchor as before. Progress
  remains `rise / (0.45 × screen height)`; scale now reaches the deck's 0.70, rather than
  the old grid's 0.50, at full travel, and gives exponentially beyond that.
- The bottom edge stays under the finger. A caught page blends under it over 120 pt.
  Release carries size, position, height, crop and corner velocity onto separate springs.
  It starts from the last *displayed* pose, including the crop, so a final unrendered
  touch update cannot produce a one-frame jump. There is still no release haptic.
- Tabs again reverses the current flight from its position and velocity. Opening a card
  starts at its actual pressed presentation frame, including depth scale. Horizontal
  swiping can catch an entry: the entering page follows the deck continuously, and other
  cards shed their remaining entry offsets over 90 pt of travel before settling.
- Settling occurs within 0.5 pt of the destination, with less than 0.1 pt of movement per
  sample. Keyframes share a clock set after their arrays have been built. Completion
  tokens prevent an interrupted flight from later hiding or landing a newer one.

### Verification

`-RiseTabDeckAudit` uses an isolated four-tab session with local fixtures and a live WebKit
page. It records positions/timing, verifies the first corner keyframes for *all* entering
cards, horizontal snapping, session-order preservation, reversals, horizontal catches,
strong flicks, swipe-to-close and its cancellation, dark mode and the last remaining tab.
The first complete simulator run passed 32 checks: button flight 0.308 s and approximately
17 ms from action to the first render-server commit. The first radius was 62 pt (that
simulator's screen), easing to 22 pt. These are simulator measurements, not a physical
120 Hz capture. Record the simulator replay separately to inspect the real displayed
frames; `drawHierarchy` can return a stale snapshot while a scroll view's layers animate.

The physical iPhone 14 Pro also passed all 37 motion checks. Its button flight was
0.308 s, with approximately 15 ms from action to the render-server commit. This verifies
the real device paths and timing; it does not measure physical display scan-out or certify
an uninterrupted 120 Hz refresh rate.

The 16 October follow-up adds title isolation, left-stack depth scaling, full-size right
cards and vertical centring checks. Verify real left/right finger drags in Device Hub
as well: programmatically changing scroll offsets or invoking scroll delegates cannot
detect touch-routing regressions.

The initial closing follow-up passed 71 deck checks and 108 interaction checks on Simulator.
It checks opacity throughout the committed offscreen flight, cancellation, reflow from
the neighbour's displayed position, closing the rightmost slot as the scroll range
shrinks, and closing during the incoming stack's animation. A caught entrance restores
its surviving cards' full size and final corners during reflow. The test target also
builds successfully; the recorded replay was inspected for the closing handoff.

The subsequent interactive-close pass passed 83 deck checks and 108 interaction checks
on Simulator. It additionally verifies that the predecessor moves right during the drag,
grows and brightens with progress, follows a reversed finger, returns on cancellation,
and becomes focused after the close. Release starts from its displayed position and its
spring is not replaced when the discarded view is removed. The replay also covers catching
a cancellation with a new close or a horizontal swipe, and the first card's successor
moving left when no predecessor exists.

---

## 5. Performance: what was measured and why it matters

Measured on the iPhone (ProMotion, iOS 27.2) unless noted.

- **120 Hz needs opting in.** iPhone apps run at 60 Hz unless the Info.plist has
  `CADisableMinimumFrameDurationOnPhone` = YES. Display links ask for 60–120 Hz, preferring 120.
- **Drive frames from the display link, on its `targetTimestamp`.** Compute every value as a pure
  function of time, which also makes it replayable.
- **But a display link stops whenever the main thread does.** Anything that has to keep moving
  through other work, such as the tab switcher's flight while New Page brings the keyboard up,
  should be precomputed from the same function and handed to Core Animation as keyframes, which
  run on the render server.
- **A fast pinch is over in about 0.1 s.** Any stall at its start loses the whole gesture: the
  page sat still, then appeared as an already-small card ("it kinda skips the animation").
  - `drawHierarchy` of the page cost 26–34 ms.
  - Creating `CHHapticEngine` on the main thread also stalled it.
  - Starting cost 40–88 ms in total.
  - Fixes:
    - The card is a `snapshotView(afterScreenUpdates: false)` replica, at 4–5 ms. It's static and
      renders inside 3D transform layers.
    - The haptics engine is made and started on a detached task.
  - Starting now costs about 8 ms, at most one dropped frame.
- **Keep work out of the release.** The model request waits 0.35 s; the haptic engine is already
  running.
- **Measuring the summary** (SwiftUI `sizeThatFits` for a 1355 pt summary) took about 40 ms.
  It happens while the card swings slowly, so the card moves under a point; left as is.
- **The reveal's blur** needs about 11 offscreen passes in one frame (seen in an Animation Hitches
  trace); work per frame peaks around 6 ms.
- **The live-page handoff must stay cheap too.** A close on apple.com had 88 steady 120 Hz
  callbacks, then gaps of 19, 14 and 33 ms just after it finished. Three real-device replays
  reproduced 21–33 ms gaps there, despite the log's cleanup block taking only 1–4 ms.
  - Time Profiler caught `CHHapticEngine`/`CHMetrics` destruction and the audio session's
    synchronous XPC in the display-link autorelease pool, outside that cleanup measurement.
    Engine shutdown and release now run on a worker, also when a scene ends during preparation.
  - SwiftUI also updated its environment and bridges, then destroyed the hosting view after
    the Core Animation commit. Retaining the host alone still left a first-close hitch.
  - Each browser now keeps one light summary hosting controller as a child. Its hidden view
    moves directly between the attached scene and the browser, so it never leaves the window
    at a handoff. Each new scene still has a fresh reveal model and request; the model is
    installed when its summary arrives. The page replica and scene are released normally.
  - Three long-summary closes on the iPhone then had 88 close and 61 post-close callbacks
    each, with no dropped callbacks and a worst gap of 8.4 ms; cleanup was about 1.1 ms.
    Animation Hitches also reported no rendered hitches in that capture, with the closing
    frames at 120 Hz. Device regressions cover fresh text on successive summaries, release of
    old scenes, and catching a close without losing its summary or the page's scroll position.
- **Real pinches dropped single frames** with Rise's own work at 0.1 ms. WebKit was busy following
  the same fingers, which is why its pinch and pan are now ended when Summarise takes over.
- **The close itself** runs at a steady 120 Hz: 88 of 88 frames on a real close.
- **Tabs, then New Page within 100 ms** hitched (he noticed; it was real). Measured with the
  `tabsNew` replay and Time Profiler:
  - The Tabs press held the main thread 45–75 ms: `drawHierarchy` for the card (about 27 ms) and
    blurred copies for the grid's crossfade.
  - New Page held it about 90 ms, then dropped about 160 ms more. Of that, about 37 ms was
    `BlurCrossfade` drawing the bar's contents at 3× and blurring them on Core Image, and the
    rest was the keyboard: `becomeFirstResponder` and `UIKeyboardSceneDelegate` reloading the
    input views. That's system code that can't be moved off the main thread.
  - New Page alone did the same; together it showed because the switcher's display-link flight
    froze through it.
  - Fixes:
    - The switcher's flight moved to Core Animation keyframes.
    - The panel's spring is flushed to the render server before the field is focused
      (`SearchPanel.focus()`).
    - Blurred copies are drawn at 1.5 px per point of blur (1.5× for the panels' 1 pt), so
      about 4× fewer pixels to draw and blur.
    - The moving page is a replica, and its card's picture is drawn after takeoff.
  - After the fixes, an Animation Hitches trace of all six rounds shows no Tabs+New Page or New
    Page frame later than 8 ms. Tabs alone still has a late first frame (about 30 ms of work
    before its first commit, from rest), with a steady 120 Hz after it.
- **Delayed button/card takeoff (14 October 2026):** the grid's blurred snapshot still ran
  before `settle`/`grow`, and selecting another tab did WebKit/tint/session setup before
  `dismiss`. The native `InteractionAudit` measured action-to-render-server commit at
  50–57 ms on the simulator. `fly` now explicitly flushes its keyframes before preparing
  the grid crossfade; selecting the live page happens after `dismiss` starts its flight.
  The same audit measured about 13–28 ms for button entry and 1–3 ms for opening cards.
  These are simulator commit timings, not physical display latency. Springs, durations,
  120 Hz requests, and catching/turnaround remain the same. Subsequent feedback asked for the
  other cards to be waiting behind the shrinking page. Button entry now sets the grid fully
  visible before committing the flight and makes no incoming blurred copy. The outgoing
  grid crossfade when choosing a tab still runs after the flight's first commit.
- **Core Animation keyframes play at 60 Hz unless asked.** Measured with the `tabsPress` replay
  (nothing else asking for frames): the switcher's flights ran at 60 Hz except while the grid's
  UIKit crossfade ran alongside. With `preferredFrameRateRange` 80–120 on each keyframe animation
  they ran at 120 Hz for the first 0.35–0.45 s, then iOS still dropped to 60 for the slow end of
  the flight (0.75 s into the card, 0.52 s back). A display link that does nothing, asking for
  120 Hz, held from the flight's start to its landing, keeps every frame at 120 Hz. The replays
  that record frames with a display link hide this, as their own link holds the screen at 120.
- **Finger tracking needed the same rate request.** An Animation Hitches trace of `tabsDrag`
  showed the slow drag and reversal at 60 Hz, then 120 only after letting go. Holding the
  switcher's own rate link from `prepare` through dragging, catching and landing changes both
  of those tracking phases to 120 Hz on the iPhone. The replay polls the presentation layers
  without a display link so its measurement cannot make the screen faster itself.
- **Opening the panel's keyboard** still costs the main thread about 160 ms, and closing it
  (`resignFirstResponder`) about 47 ms. Only what runs on Core Animation stays smooth through
  that.
- **Search and Downloads panel tracking (16 October 2026):** the panel pan did not hold a
  high-refresh display link, unlike the tab switcher. `PanelMotion` now requests the screen's
  maximum rate (up to 120 Hz) throughout tracking and the release spring, then invalidates its
  link. It also stops when the scene becomes inactive. This includes both Downloads detents.
  A focused Simulator replay found repeated search closes doing 36–40 ms of synchronous work
  before the first commit, with a cold first close at 317 ms. A symbolicated `sample` capture
  attributed release work to keyboard resignation and `BlurCrossfade` snapshot/blur preparation.
  Closing now flushes the sheet and page-return animations before that work. The first fixed
  replay committed them in 2.1–4.9 ms; total synchronous release work still took about 40 ms,
  but now runs after the render server can start moving. Drag updates averaged 0.5–0.6 ms.
  These are Simulator CPU/commit measurements, not a physical iPhone 120 Hz verification.
  The Simulator reports a 60 Hz maximum, which the request respects.
  `-RisePanelMotionAudit` replays slow tracking and release without an extra measuring display
  link; `-RiseWaitForProfiler` pauses at `Library/Caches/PanelMotionAudit/ready.txt` until a
  sibling `go` file exists. Search and Downloads drags also retain the last 20 frame/work logs
  in `Library/Caches/Panels/log.jsonl`, written on a utility task after settling. Read them with
  `scripts/panel-motion-log.py --simulator <UDID>` or `--device <ID>`. Long display-link callback
  gaps identify main-thread stalls; they do not establish a rendered hitch while Core Animation
  is running independently.

---

## 6. Bugs and pitfalls that were hit

- **The page moved underneath while hidden.**
  - Cause: two fingers pan a `UIScrollView` while pinching, one finger lifting early drags it, and
    touches pass through while closing. The live page then reappeared a little scrolled.
  - Fix: save and restore its offset and zoom, and stop WebKit's recognisers.
  - The log notes "page moved" whenever this happens.
- **Depth sorting in `CATransformLayer`.** The tipped card sorted behind the summary's layers. It
  needs `zPosition` 2000 and to be added last.
- **Measuring SwiftUI too early.** The summary measured 0 tall on arrival. Reset `rootView`, then
  `layoutIfNeeded`, then `sizeThatFits`.
- **Blur clipped by a container** left a hard line mid-reveal (in the playground). Don't put
  blurred text in a clipping scroll box.
- **Crease hairline** (from the old unfold). The backdrop showed through a 1 px seam; overlap
  layers by a point.
- **A caught gesture.** `gestureRecognizerShouldBegin` must allow the pinch while the card can be
  caught, not only when no Summarise is running.
- **Stale `summary` task on catch.** The close cancels the request; the catch must clear the task
  so a new one (or the reuse path) can start.
- **A Core Animation flight's model is already at the end.** Read `layer.presentation()` for where
  it shows, or the flight's own function of time. Finishing must check the flight is still the
  current one, as removed animations call their completion too.

---

## 7. Tools for checking motion

- **The playground:** `Playgrounds/summarise.html`.
  - **Serving:** with a server that supports Range requests, so the video can seek (Python's
    `http.server` doesn't).
  - **Controls:** dials grouped by phase; a scrubber that moves the simulation and the Arc video
    together; replays "as in video" for the pinch and menu runs; Copy values.
  - **Out of date:** its pinch dials describe the old fold and unfold, which the app no longer
    has. It keeps Arc's original backdrop palette for reference; the app uses Rise's softer
    icon palette. Its backdrop's purple/pink names correspond to the app's cool/warm glow names,
    with the same paths and timings. Its other card, swing, reveal, bar and close dials still match
    `SummariseMotion` by name.
  - **Headless check:** `--headless=new --virtual-time-budget`, with a unique `--user-data-dir`
    per run.
- **In-app replays (DEBUG):**
  `xcrun simctl launch … dev.bartosz.Rise.iOS -RiseSummariseReplay <folder> [kind]`. On a device,
  `xcrun devicectl device process launch --console … -- -RiseSummariseReplay <folder> [kind]`.
  - Default (a hard pinch from the right edge), `gentle`, `menu`, `live` (real model): run on
    Summarise's manual clock, saving frames at set moments and `result.txt`.
  - `regrab`: closes the card, catches it with a pinch 0.12 s in, and checks the summary comes
    back and the page is restored after being nudged 40 pt.
  - `timing`: on a real page in real time, pinches, closes once revealed, catches and closes again,
    printing the frame gaps by phase.
  - `close`: on Apple's homepage, opens and closes a settled 1026 pt fixture summary three
    times in real time, using only the scene's own frame log. Nothing holds the old scene alive
    after the handoff. Check both the close and the following half-second in the on-device log.
  - `tabs`: swipes up the bar in real time (a hard flick, the card tapped back, a short swipe that
    springs back) and writes the moving page's frame and its title's opacity and place each frame
    to `tabs.csv`, as shown (the presentation layers), since the flight's model values jump to the
    end.
  - `tabsDrag`: adds a 1.2 s slow drag, a reversal and cancellation, then catches a page growing
    back and drags it into its card again. It records presentation layers by polling, with no
    recording display link to mask the real refresh rate. For a device, a destination such as
    `caches:tabs-drag` saves under the app's `Library/Caches`, which `devicectl device copy from`
    can fetch; absolute paths still work for Simulator replays.
  - `tabsFlick`: adds three short, strong flicks, each with a final touch update immediately
    followed by release, before its new pose can display. This checks the drag-to-flight
    handoff rather than only a long drag whose last pose has already reached the screen.
  - `more`: opens More over Hacker News and leaves it open, to look at the receded page's corners
    (concentric with the screen's: its corner radius, read from UIKit, less the page's inset).
  - `tabsPress`: presses Tabs and taps the card back three times on Hacker News with nothing else
    asking for frames, for an Animation Hitches trace of the rate the flights really run at.
  - `tabsNew`: on a real page, six rounds of Tabs and then New Page 100 ms later, New Page alone
    and Tabs alone, printing each press's main-thread cost and every frame the main thread
    dropped. Its drops show the main thread, not the screen: check what showed with an Animation
    Hitches trace of the same replay.
- **The on-device log:** every Summarise is recorded (the last 40, in the app's caches).
  - **Contents:** its events with times, every frame during the pinch, flight, reveal and close
    (otherwise only dropped ones), and half a second of the page's frames after it ends.
  - **Reading it:** `python3 scripts/summarise-log.py --device A0008B8F-939F-5363-85C4-9027E8AA261D
    --last 1` reports the phases' frame rates and each dropped frame with what happened near it.
  - **When to use it:** when he says "the last one was choppy", read that record.
- **Animation Hitches traces:** `xcrun xctrace record --template 'Animation Hitches' --device
  00008120-000275180C10201E --time-limit 30s --launch -- dev.bartosz.Rise.iOS …`. xctrace knows the
  iPhone by that UDID, not devicectl's.
- **Frame strips from recordings:** `ffmpeg` at 60–120 fps, tiled with Python (zsh trips over
  filter strings). Write each strip to a new filename; image viewers cache by path.
- **XCTest can't reach the Simulator here** ("failed to bless service hub"). Tests compile with
  `xcodebuild build-for-testing`; behaviour is verified with the replays instead.

---

## 8. Arc Search, as measured from the recording

These came from `Playgrounds/summarise-reference.mp4`, frame by frame. The values still in use
are in sections 2–3; the rest is kept for reference.

- **Pinch:** the page snapped to 97.6% when the pinch was recognised and followed the fingers to
  about 89%. The fold began around 92.7%.
- **Fold (dropped):** the page creased in the middle as a mountain fold, about 204°/s, easing in,
  flattening at about 87.5%. It held edge-on for 0.09 s, while Arc's bar slid away in 0.07 s.
- **Flip up (dropped):** turned upright in 0.2 s. Scale on (10.5, 0.95, 6), rise on
  (20.5, 0.75, 16), perspective 2000.
- **Card, swing, reveal, glows and close:** as in section 3; those are Arc's numbers apart from
  `textGap` and `barExit`.
- **Close:** about 0.3 s to fill the screen, with the page below the card unfolding (dropped in
  Rise).
- **Safari's pinch into its tabs** (from his recordings): it follows the fingers at their scale,
  settles in about 0.3 s, overshoots smaller on a hard pinch, and always flies from wherever the
  pinch left it to the one right place. Rise's settle is a little slower, by his choice.
