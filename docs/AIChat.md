# The AI chat panel

A chat beside the page, made to look and move like Dia's chat panel, docked and animated like
Rise's own DevTools. ⌘E or View › Show Chat opens and closes it. It answers with the model and
provider chosen for Rise's other AI features (`ModelService`), and attaches the page in front
when it opens, as Dia does.

The code:

- `Sources/Rise/AIChatStyle.swift`: every measurement and color.
- `Sources/Rise/AIChatPanel.swift`: `AIChatView` (header, conversation, composer, the lift),
  `AIChatTurnView` (one exchange), `AIChatPanel` (the docked card, its width and springs) and the
  `BrowserController` wiring.
- `Sources/Rise/AIChatComposer.swift`: the composer, its input (TextKit 1), caret and send button.
- `Sources/Rise/AIChatMessages.swift`: page chips, the question's bubble and the answer.
- `Sources/Rise/AIChatMarkdown.swift`: the answer's Markdown, block by block.
- `Sources/Rise/AIChatConversation.swift`: attachments, turns and the prompt.
- `Tests/RiseTests/AIChatTests.swift`.

## Measured from Dia

Measured from 2× screenshots of Dia's panel in Light, and 120 fps recordings of a question being
sent. All values are in points.

- Panel: 480 wide by default, 320 at the narrowest Dia allows. Rise also keeps the page as wide
  as DevTools leave it. A dragged width is remembered (`Rise.AIChatWidth`).
- Header: 48 tall, New Chat at the left and Close at the right, both centred 26 down. Dia's
  squiggle and sidebar buttons are left out on purpose.
- Conversation: text 20 in from the left; bubbles and page chips 11 in from the right. The first
  exchange starts 15 under the header.
- Question bubble: 14 pt text on 24 pt lines, padded 16 × 10.75, radius 17. At most 75% of the
  composer's width.
- Page chip: 184 × 54, radius 12, with a 30.5 × 38 tile for the favicon and 13 pt title and host.
  The title is regular weight.
- Remove button: each page in the composer has one, shown while the pointer is on the page.
  - Shape: an 18 pt disc centred 4 pt in from the chip's top-right corner. Its cross is 6.5 pt
    across with 1.5 pt strokes.
  - Colors: muted while the pointer is on the chip (#C7C7C7 with a dark cross; #505050 with a
    light one in Dark). High-contrast while it's on the button (#171717 with white; #EDEDED with
    near-black).
  - Hit area: the chip row leaves room for the part past the corner, so it still takes the click
    there.
  - Taking off the page in front keeps it off, even if it was also added from the + menu, until
    another page comes to the front.
- Answer: 15 pt text on 25 pt lines, 14 between paragraphs. "Thought for N seconds" (13 medium)
  sits 44 under the bubble and 12 over the answer. Copy and Regenerate sit 12 under the answer.
- Composer: 8 in from the panel's sides and bottom, radius 18, a 0.5 border.
  - Height: 60 tall with nothing in it; 100 plus 70 for a row of page chips when in use.
  - Text: 16 pt on 24 pt lines.
  - Buttons: their row is centred 30 up from its bottom.
  - Shadow: opacity 0.12, blur 3, 1.5 down. The card's layer is flipped, so down is positive.
- Caret: 2 wide and 18 tall, centred on the 24 pt line. NSTextView would draw it 1 wide and as
  tall as the line box. The input view draws its own and widens what AppKit erases.

Left out for now: Dia's suggestion chips over the composer, and the chevron that expands its
reasoning. The camera button is disabled, since screenshots of the page can't be attached yet.

## Motion

- The panel opens and closes on DevTools' springs (response 0.185, bounce 0.2 to open; 0.17 and
  0.15 to close), not Dia's, so it moves like the rest of Rise.
- Sending lifts the question and its pages off the composer, over it in `flightLayer`, to their
  places. The conversation scrolls the new exchange to the top as they go.
  - Rise: one spring `p` with response 0.28 and no bounce, 90% of the way in 0.17 s as Dia's is.
  - Bubble: starts with its text over the question's first line, its left edge with the pages',
    reaching to its own right edge. It draws in to its width ahead of the climb, at
    `1-(1-p)³`, which matches Dia frame by frame.
  - Pages: Dia leaves them at the top. Rise flies them too, from the left of the composer to the
    right of the panel, at the same pace.
  - Answer: "Thinking…" rides under the bubble and fades in over the last 40%.
  - Scroller: hidden while the conversation scrolls itself, so it doesn't flash.
- Answers stream with the find bar's token effect (`TokenStream`, `TokenTextView`). The words
  fade and sharpen in place. They don't slide in (`tokenLayout.travels = false`), as Bartosz
  asked.
