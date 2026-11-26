# Page annotations and contextual questions

On desktop, select readable page text and choose **Ask About Selection…**, or press
**Control–Command–A** (**View → Annotations → Annotate Selection**, also remappable in Keyboard shortcuts).
Rise opens a question panel directly from the selection's bottom-right corner, with the
same `CardMotionAnimator` and selected spring as the pinned Calendar card. The input says
“Ask about this selection…”. Clicking outside, Escape or Close folds the panel into its
number over 180 ms. The contents fade within 58 ms while the number fades in, with no blur.
The landed surface stays present until Chromium acknowledges
the real badge's paint, then crossfades over 60 ms. The native and page shadows crossfade
together, preventing either a missing badge frame or an extra shadow appearing at the end.
The badge also fades, including its shadow, as the panel opens. Click the number to reopen the question and
answer. Collapsed badges take their background, border and shadow from the actual native
Ask panel, including theme changes. Middle-click a marker (or an expanded panel) to remove
it; right-click also offers Remove Annotation. **View → Annotations → Remove All Annotations on This Page**
clears that page's notes and conversation.

The question card is the existing `FindBar` in anchored Ask mode: the same border,
shadow, typography, input shimmer, token rendering, answer-height spring, copy and
regenerate actions, model choice and service clients. It stays within the page viewport,
moves with its marker, and also works in a Peek or split pane. Marker targets keep their
identity across page mutations so a refresh between mouse-down and mouse-up cannot swallow
the click. Annotation numbers never
change when a neighbour is deleted. Quote anchors retain the exact passage, surrounding
text and UTF-16 offset; they reattach after reload and DOM changes without wrapping or
editing the article's text. Constructed stylesheets in the document and closed shadow
root preserve marker styling on pages with strict inline-style policies (see
[adoptedStyleSheets](https://developer.mozilla.org/en-US/docs/Web/API/Document/adoptedStyleSheets)).
Main-document readable text is supported; editable fields
are excluded. An unmatched quote remains saved rather than being attached to unrelated
text.

Notes, drafts and completed answers persist locally beside the session in
`annotations.json`, keyed by page URL rather than tab identity. Ordinary section hashes
share notes, hash-router pages remain separate, and query strings remain significant.
The file uses atomic writes. These notes are not included in tab sync. Source page text
is read when a question is submitted and isn't persisted in this file.

All annotations on a page share one message history. The unchanged instructions and
whole page text (Find's existing 120,000-character limit) precede prior user/assistant
turns. Earlier user messages are replayed exactly, including their then-current annotation
index. The current question includes the current numbered index, so the model can refer
to other annotations. Deleted annotations and their turns are removed. Per-page limits
are 100 annotations and 80 completed exchanges, with an 80,000-character history budget;
long selections, answers and the current quote index are bounded too. Provider defaults
control caching: Rise doesn't promise an hour or add an unsupported TTL. This follows
[OpenAI's prefix caching](https://developers.openai.com/api/docs/guides/prompt-caching)
and [OpenRouter's provider-specific defaults](https://openrouter.ai/docs/guides/best-practices/prompt-caching).
OpenCode keeps its own service defaults.

# Smarter tab search

**Shift–Command–A** still filters tabs immediately as you type. Matching also includes
cached page descriptions and headings, and repository names, README introductions,
topics and known pull/merge-request states and summaries. Metadata is read from already
loaded pages and persisted in `tab-search-metadata.json`; search does not load every
background page or send full page bodies to the model.

Enter on a descriptive query (four or more words, a question, or no literal matches)
asks the same selected AI provider to rank the tabs. The input uses Find's `InputShimmer`.
The returned IDs filter and order the existing sidebar rows; arrow keys and Enter select
as usual. Enter on an explicitly highlighted result always selects it. Editing or ending
the search cancels pending work, and stale results cannot replace a newer query. Closed
or navigated tabs and invented IDs are excluded; malformed responses and failures show
an inline message. Split pairs stay together and choose the matching half.

The model receives at most 120 locally shortlisted candidates and a 40,000-byte metadata
packet in total. Ordinary short literal searches retain their existing Enter behavior.

Validation:

- `scripts/test.sh --filter 'PageAnnotationsTests|TabSearchIndexTests|AnnotationConversationTests|SmartTabSearchTests|FindBarTests|TabOrganizationTests|PageAssistantTests|PeekFindTests|KeyboardShortcutsTests'`
- `RISE_LIVE_STABLE_SIGNING=1 RISE_SKIP_CAPTURES=1 RISE_PEEK_OUT=build/annotation-proof python3 scripts/test-chromium-live.py Tests/Live/ChromiumAnnotationsChecks.swift`
- Add `RISE_STRICT_CSP=1` to check a page that rejects inline styles.
- Add `RISE_REAL_AI_CHECK=1` for small live-model tab and annotation requests. The ordinary
  integration check uses a controlled streaming transport and never needs an API call.
