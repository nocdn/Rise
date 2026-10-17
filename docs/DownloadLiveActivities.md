# Download Live Activities

Accepted iPhone downloads start an ActivityKit activity. `RiseDownloads.appex` supplies its
SwiftUI views; `Shared/DownloadActivity.swift` supplies the same attributes and stop intent to
the app and extension. The app declares `NSSupportsLiveActivities`; no push service or extra
account is involved. The app target depends on and embeds the signed extension.

The reference is Safari's iPhone 14 Pro download activity, supplied on 17 October 2026:

- The expanded island uses one row, an approximately 90-point total system surface, a
  38-point Rise icon, 17-point regular title, 14-point byte count, and 48-point ring with a
  rounded stop square. Content is inset and kept clear of the camera.
- Compact leading uses the exact arrow path and 1.8-point stroke from the Downloads tile,
  in white; compact trailing uses a 24-point ring. Minimal uses an 18-point ring. Attached to
  the island, the system puts it about 7 points from the island's edge but 9.33 from its top
  and bottom, so a 9.33-point leading content margin evens the three gaps. The minimal view is
  only as wide as its content: a view that fills its space, such as a GeometryReader, collapses
  it to a sliver.
- The Lock Screen uses the same content in a 72-point row, with a smaller 38-point ring,
  medium title, translucent dark tint and white text. The system supplies the outer surface.
- `ActivityRise` is the app's compiled 120-pixel fallback icon, copied into the shared asset
  catalog. Its small resolution is intentional: ActivityKit rejects oversized images.

`DownloadLiveActivities` starts synchronously while the app is foregrounded, coalesces
updates to one per second, and serializes the final update after pending progress. Completion
ends the island and leaves the completed Lock Screen card for three seconds; failure and
cancellation dismiss immediately. A stop button uses `StopDownloadIntent` in the app process
and the existing `MobileDownloads.remove` path, including partial-file cleanup. Stopping is
immediate: the activity ends without waiting for progress on its way. From iOS 26 the intent
runs in the background first and then brings Rise forward (`.foreground(.deferred)`); before
iOS 26, `openAppWhenRun` opens Rise first and the stop runs once it is open. Concurrent
downloads have separate IDs. Tapping the card opens Downloads via `rise://downloads`.

A scoped UIKit background task lets existing WebKit transfers finish while iOS grants time;
the Live Activity does not turn WKDownload into a persistent background URLSession transfer.
After app termination, the next startup ends abandoned activities. Disabling Live Activities
or reaching the system's activity limit never prevents the file download itself.

Build and install with `scripts/restart.sh --ios --device <device-id>`. A Debug build accepts
`-RiseDownloadActivityAudit`, which exercises real WKDownloads and ActivityKit: updates,
completion, failure, the stop intent, concurrent cancellation and partial-file deletion. Add
`-RiseDownloadActivityPreview` to leave a deliberately slow local transfer for a screen check,
and `-RiseDownloadActivityMinimalPreview` as well for a second one, which shows the island's
minimal views; stop them from the island afterwards, or run the audit again to remove them. Results are in `Library/Caches/DownloadActivityAudit`.
The tests leave existing downloads and browser session data intact.

On this test Mac, iPhone Mirroring hid compact island graphics; Device Hub's physical-phone
screen displayed the arrow and ring correctly, and its Home and Screenshot buttons take a
full-resolution capture from the phone to `~/Desktop`. Expanded rendering and actual stop-button
invocation were checked on the iPhone 14 Pro. The stop action stayed on the Home Screen and
removed the partial file. The simulator was not used as evidence for island rendering.

Apple references: [Live Activity views](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities),
[interactivity and app-process intents](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).
