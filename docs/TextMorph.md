# Native text morphing

The iOS toast uses UIKit and Core Animation. Its reusable `TorphTextView` ports
Torph's **text-only** engine (`numbers: false`) from commit
`d79a5aa63226acf97d49c3e34fafb2e85c07b026` of https://github.com/lochie/torph.
The MIT license is bundled as `Torph-LICENSE.txt`. Numeric rolling, editable caret
matching, HTML nodes and framework adapters are not part of this text-label port.

`TorphText` in RiseCore handles ICU word/grapheme segmentation, forward LCS with
earliest-match ties, exact reordered words, a 0.4 similarity threshold, pairing
only inside unchanged-word gaps, unique IDs, separators and bounded diff work.
Changed word fragments are flattened to **Swift graphemes**, including punctuation
fragments, before character matching. This avoids splitting emoji or indexing an
entire `repository` span as one letter when `repository...` becomes `repository`.

`TorphTextView` performs FLIP from presentation positions, fading exits over 25%
of the morph and arrivals over 50% after a 25% delay. Groups of six fully replaced
fragments recede together at 0.8 scale with the original 45%/35% fade fractions.
Whole lines are shaped by Core Text before assigning glyphs to fragments, retaining
kerning, joining scripts, ligatures, fallback fonts and composed emoji. It exposes
one complete accessible string. Duplicate values do nothing; interrupted morphs
cancel once, completed morphs complete once; detachment clears the animations.
Reduced Motion and disabled mode render directly. Empty transitions retain their
old line box until outgoing fragments finish.

`TorphAnimation` samples curves at intervals shorter than a 120 Hz frame and runs
them in the compositor. Its size transition carries bounded momentum on retargets
and keeps the existing phase when the target changes by less than half a point.
Text, toast width and shadow use Torph's original 400 ms cubic
`(0.19, 1, 0.22, 1)`, with its original proportional fade durations, delays and
scales. The toast's existing entrance, dismissal and icon swap remain separate.

## Why the toast's width sometimes skipped

The previous layout measured `label.intrinsicContentSize` on every parent layout.
Changing the label and swapping the spinner could trigger a layout before the width
animation was created. That put the model at the final width already. Fast
“Already starred” responses and some success responses therefore animated nothing.

The toast now stores its intended layout width independently. Text updates snapshot
the old geometry first, then create explicit animations with that starting size,
even if the toast hasn't committed its first frame. Parent layouts only apply the
stored size. The background, text container and shadow share the same sampled curve.

A second skip occurred when Core Animation's transaction stayed open during native
menu or icon setup. The port originally assigned an absolute start time; time could
run out before the first frame was committed. Animations now have a pending start
at commit. Delayed fades use a relative animation group, preserving Torph's exact
100 ms delay. A held-transaction regression checks the actual blue background's
presentation width after a 450 ms delay, not just the outer layer's animation data.
Toast geometry samples are included in the existing `Panels/log.jsonl` diagnostics.

## Toast interaction

Upward and sideways dragging tighten Snap's rubber band to
`0.42*x / (1 + abs(0.42*x) / 22)`, giving resistance from the first point;
downward movement follows the finger. Release carries the rendered
velocity into a sampled, compositor-driven flight. Snap's 0.22 s projection,
5000 pt/s input cap, 280 dismissal stiffness and 0.90 damping ratio inform the
trajectory. It aims past the visible edge so a fast flick keeps moving quickly
until the plaque is gone. Returning uses stiffness 340 with the same damping ratio.
The existing spinner, typography, box and entry spring stay the same.
Downward dragging and flight scale from 1 to 0.9 by the toolbar, mirroring entry.
The toast requests a fixed 120 Hz rate for tracking and compositor animations on
ProMotion devices (capped at the screen's maximum elsewhere). Right padding is
3 pt narrower; the leading icon and text spacing stay the same.

## Verification

- `scripts/test.sh --filter TorphText`: all 50 upstream text cases cycled forward,
  backward and forward again, plus Unicode, whitespace, repeated words, punctuation,
  adversarial ID sequences, large inputs and anchors.
- `-RiseTorphTextAudit`: native instant/1/12/45/150/600 ms completions for both
  outcomes, forced parent layouts during updates, intermediate presentation widths,
  80 rapid retargets, lifecycle callbacks, accessibility and glyph cleanup.
- `-RiseTorphTextAudit -RiseTorphPreview`: repeats the three toast labels for visual
  inspection. These audits use an isolated browser and never touch saved tabs.
- `-RiseTorphTextAudit -RiseTorphWidthAudit`: samples both the blue surface and
  outer layer across normal and deliberately held display commits.
- `-RiseTorphTextAudit -RiseToastInteractionAudit`: checks resistance, reversal,
  cancelled gestures, velocity continuity, fast-flight duration and native cleanup.
