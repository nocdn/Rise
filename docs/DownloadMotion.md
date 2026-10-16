# Download flights on iOS

`MobileDownloadFlight.swift` carries an actual `DownloadsPanel.Row` from the page's
touch into More. `DownloadOriginTracker.swift` observes touches without recognizing,
preventing or delaying WebKit's gestures. The point is saved in window coordinates
when WebKit creates the download and retained through its confirmation. Declining
or removing the transfer before it starts produces no flight.

## Reference and timing

Measured from Bartosz's `dia downloading animation.mp4` (16 October 2026): 3024×1964,
44 original frames, variable frame times, 0.795 seconds. Decode with
`-fps_mode passthrough`; constant-rate extraction duplicates frames.

- Around 0.10 s, a small download row emerges just below the click.
- By about 0.17 s it has grown; it stays near the click through roughly 0.30 s.
- From about 0.30–0.43 s, it accelerates left and upward around a shallow curve.
- It shrinks near the destination, disappearing into the toolbar around 0.47–0.50 s.

Rise's desktop implementation is `Sources/Rise/DownloadFlight.swift`, tuned in
`Playgrounds/download-flight.html`. The mobile version keeps its cubic easing
`(0.42, 0, 0.72, 0.19)`, shrink after 60% of spatial progress, exponent 1.6,
direction-aware impact and 0.34 s/0.4-bounce recoil. It carries a row instead of the
desktop blue arrow. A downward-facing normal gives the recorded initial dip; the
curve adapts to a destination at the phone's bottom right.

## Mobile values

- Row: 232×64 points at 0.86 resting scale (about 200×55), the Downloads list's
  own fonts, colours, progress ring and corners, with its options button hidden.
- Pop: starts at 42% of that scale; spring angular frequency `2π/0.24`, damping 0.78.
- Flight: 0.44 s at 600 points, distance exponent 0.2, clamped to 0.34–0.54 s.
- Quadratic control: 35% along the throw plus a normal displacement of 36% of
  its length; the control stays inside the window.
- Tilt: at most 0.055 radians during the curve. Final scale 0.025; opacity stays
  full until the last 10% of spatial progress, while the row enters the button.
- Impact: a velocity impulse on the incoming tangent, about 2–3 points of travel,
  at most two degrees of tilt and a small squeeze; settles over 0.55 s.

More has a separate `moreLanding` container for its impact. Its button keeps its
normal press scale, haptic and symbol swaps. Impacts are additive and independently
keyed, so concurrent arrivals coexist. Flights and impacts are precomputed at
120 samples/second and run on Core Animation; a lightweight rate request holds
120 Hz while they play. No per-frame WebKit or bitmap capture is involved.

The confirmation dismisses before the transfer/flight begins. A collapsed toolbar
opens to receive it. A missing or stale touch uses the page's centre. Reduce Motion
skips the throw. Losing the active scene removes the overlay, its rate request and
only its own button impact.

The single rigid download-start haptic plays at arrival, on the flight's clock as
More begins recoiling, rather than when Download is pressed in the confirmation.
The generator is prepared at takeoff; the existing rate link fires it once and is
invalidated if the flight is removed. Reduce Motion receives that pulse immediately
because there is no flying row. The separate three-pulse completion pattern is unchanged.

## Verification

`-RiseDownloadFlightAudit` runs 24 native checks of the displayed presentation
layers, path, landing, row style, concurrent arrivals, independent press feedback,
cleanup, collapsed-toolbar fallback and exactly one start pulse at arrival, with
none during flight or after an interrupted throw. It leaves a local sample link for checking
the real touch and native confirmation in Device Hub. `InteractionAudit` includes
real concurrent WebKit transfers, individual origin retention, declined confirmation
and cancellation before the destination callback; all 112 checks pass.

The simulator recording and actual link/confirmation were inspected. These checks
verify the requested 120 Hz configuration, not physical ProMotion scan-out; the
iPhone was unavailable. Use `./scripts/restart.sh --ios --simulator <id>` to restore
the normal app after an audit.
