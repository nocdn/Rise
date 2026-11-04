# YouTube autoplay on macOS

A YouTube video you open (a link, a typed address, a restored or reloaded tab, a Peek) waits on
its thumbnail and large play button instead of playing. **Settings → Tabs → Autoplay YouTube
videos**, or **Page → Autoplay YouTube Videos** in the menu bar, turns this off; it's off by default. Changing it reaches open YouTube pages without a
reload. `YouTubeAutoplay` holds the setting and the page script.

## How

YouTube has no setting or URL parameter for the first video on a watch page. Its player's
Autoplay toggle only picks the next video, and `autoplay=0` only applies to embeds. YouTube does
handle a browser that turns autoplay down, as Chrome does for sites you rarely play anything on:
when `play()` rejects with `NotAllowedError`, the player shows the video's thumbnail with the
large play button and its controls. It keeps the link's start time (`&t=`) and playlist, and
doesn't fall back to muted playback.

So a script in the page's world, in YouTube's main frame, rejects `play()` the same way for
YouTube's own players (`#movie_player` on watch and embed pages, `#shorts-player` for Shorts).
That lasts until the first trusted `pointerdown` or `keydown` in the document. Escape and
⌘/⌃ shortcuts don't count. The listener is registered at document start, so it runs before the
click or K press that plays. After that:

- A video you pick on YouTube plays as usual, as does Autoplay's next video.
- Hover previews (`#inline-preview-player`) and other sites' embedded players are never held.

`navigator.userActivation` can't be used for this, because Rise's page scripts are evaluated
with a user gesture by default. That would count as the page having been used.

## Alternatives tried

Tested on youtube.com in Chrome 156, November 2026:

- `movie_player.stopVideo()` after playback starts leaves a black player.
- `movie_player.cueVideoById()` gives the same thumbnail and play button. But the video has
  already started (and been heard) by then, and it reloads the player.

## Checks

- `Tests/RiseTests/YouTubeAutoplayTests.swift`: the setting's default, saving it, and the script.
- `python3 scripts/test-chromium-live.py youtube`, case
  `OpenedVideosWaitForPlayUntilYouClickOrTurnAutoplayOn`: in Rise's engine, the player is held,
  another video plays, and a gestured script is still held. A real click plays it, and turning
  the setting on and off reaches open pages and ones opened later.
