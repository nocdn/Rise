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
  `SummariseMotion`'s springs.
- `Apps/iOS/Rise/BrowserViewController.swift`: the gestures (the pinch, the swipe up the bar), and
  how both scenes sit over the page.
- `Apps/iOS/Rise/SummariseLog.swift` and `scripts/summarise-log.py`: the on-device frame log.
- `Apps/iOS/Rise/SummariseReplay.swift` (DEBUG only): scripted replays and timing runs.
- `Playgrounds/summarise.html` and `Playgrounds/summarise-reference.mp4`: the web playground with
  dials, and the Arc recording it was measured from.

Changing a spring in `SummariseMotion` changes both Summarise and the tab switcher.

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
- **Text materialises with the motion it belongs to.** Tab titles ride under the shrinking page
  and fade in as it nears its card, rather than already being there. Going back, they fade out
  quickly.
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
  speeds up (k²) over `barExit` 0.18 s, moving by its height + 4.
- **Coming back:** it springs back as the card grows back, with response 0.27 s and bounce 0.25.
  Arc's bar actually leaves in 0.07 s; he chose 0.18.

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

## 4. The tab switcher

The swipe up the bottom bar (from anywhere on it, even New Page) uses the same model.

### While swiping

- **Progress:** `rise / (0.45·H)`, where `rise` is how far the finger has gone up (plus the
  caught page's progress).
- **Scale:** `1 − 0.5·progress`, giving exponentially past the full travel:
  `0.5·e^(−(progress − 1))`.
- **Shape:** as with the pinch, by `k = clamp((1 − s)/(1 − cardScale))^1.3`:
  - Crop: the height goes to the card's 1.42 aspect, and the strip is cropped off.
  - Corners: the screen's own (`_displayCornerRadius`, 28.8 if it can't be read) from the very
    start, all four, easing by `k` to the card's 18. He didn't want the page square at first and
    rounding only a little way in. The Tabs press starts from them too, and growing back ends on
    them, so the real page takes over unseen behind the screen's corners.
- **Place:**
  - The bottom edge follows the finger.
  - Horizontally, the spot across from where the finger started stays under it:
    `x = startX + Δx − (startX − W/2)·s`.
- **Catching it mid-flight:** a caught page starts where it was, moving with the finger. It comes
  under the finger as the finger moves over 120 pt (`catchTravel`).
- **Behind it:** a solid, faintly warm grey, #F3F1F0 (#1A1918 in dark mode), opaque from the
  start. It replaced a blur of the page, which was awkward because it was slow to come in. The
  grid fades in with progress and grows from 0.96.
- **Refresh rate:** the 120 Hz display link is held from the start of the drag through its
  release and landing, including when catching a growing page. Requesting it only for the
  flight left the finger tracking at 60 Hz.

### When let go

- **Commit:** if flicked up faster than 400 pt/s, or let go past 25% while not moving down faster
  than 400.
- **Committed:** it flies to its card at the swipe's speed:
  - size on `releaseScale`, place on `releaseMove`, crop and corners on `placeCrop`, each
    carrying its velocity. Stopping the uncropped height at release changed both edges' speed
    abruptly even though the centre and scale kept moving, making a flick feel like a wall;
  - a hard flick dips past the card's size (in the replay: down to 136 pt wide against the card's
    179) before curving into it in about half a second;
  - no release haptic.
- **Not committed:** it springs back to the page on `cancel` from its speed.
- **Tabs button:** the page goes to its card on the same springs, as progress from rest.
- **Choosing a card:** the card grows to the page on `close`, as progress.
- **Turning around** (Tabs again, a tap on the landing page, a swipe as it grows back): it carries
  on from the flight's current speed, including its height, crop and corners.
- **Landing:** the flight runs on Core Animation, not a display link. Nothing but a new touch
  changes it, so its whole path is worked out when it starts, sampled every 1/120 s until it's
  within 0.5 pt (and 0.01 of crop) of its place and moving under 0.1 pt a frame. It's then played
  as linear keyframes: the card's bounds, position and corners; the page picture's bounds and
  position inside it; and, on the way in, every title's opacity and transform. The model values
  jump to the end at once, and the real cell takes over when the animations finish. Interrupting
  reads the flight's function at the current time, removes the animations and starts from there.
  - A finger's release starts from the presentation layers' visible page and strip crop. The
    last touch can update the model without that pose displaying, and starting from that
    unseen pose made a short, strong flick jump in one frame.
  - The keyframes are all prepared before their shared start time is set. Starting their clock
    before that work let the first visible frame skip ahead on fast flicks.
- **The page in flight** is a `snapshotView` replica (about 5 ms), scaled from the window's size.
  Its card's picture (`drawHierarchy` of the page plus the strip's colour, about 25 ms) is drawn
  only once the flight is with the render server (`onFlight`, after a `CATransaction.flush()`),
  or sooner if a tab is chosen, closed or opened first.

### Titles

- **Coming in:** the current tab's title (favicon and title) rides under the moving page: 7 pt
  below its bottom edge, centred on it. Every title fades in by a smoothstep over the last 65% of
  the way to card size (`captionFrom` 0.35), rising 6 pt into place, and lands with the page.
- **Going back to the page:** they fade out in 0.12 s.

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
- **Removing the overlay** at the end of a close costs about 25–33 ms. It happens when nothing is
  moving; deferring it only moves the stall to when the person might be scrolling.
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
