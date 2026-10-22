# Page translation on iOS

More's address row shows the supplied CodeX translation icon immediately before Reload,
with 34 pt centre spacing from Reload (Back/Forward use 30 pt) and a slightly lighter stroke
than the compact toolbar's discovery glyph (SVG stroke 1.7 versus 1.8).
It appears for a detected non-English document. Tap to translate in place to English;
the icon swaps to a small native spinner using the standard symbol animation, then back
to blue when translation finishes. Blue means enabled, and another tap
cancels outstanding work and restores the original text without reloading.
The blue-to-normal colour change is immediate.

Once per document, the compact foreground toolbar announces availability: the glyph fades
in over 140 ms with smooth easing, growing from 90% to full size, 40 pt left of More.
It then accelerates into More over 360 ms while shrinking
to 68%. The glyph slips behind the circular button's edge, staying hidden beneath its
surface even in dark mode. More receives the same small landing impulse as a download, directed right.
This cue never enables translation or adds a haptic. Panels, collapsed bars and the tab
switcher defer it; navigation, opening a panel and backgrounding cancel an active cue.
Background tabs do not announce. Reduce Motion uses only a short stationary fade.

`PageTranslationLanguage` uses Natural Language recognition on a bounded text sample,
falling back to a valid HTML language tag for short pages. English region variants are
English. Content takes precedence over incorrect language tags. Unknown pages do not
show a misleading translation control.

`ApplePageTranslator` uses Apple's Translation framework on iOS 18 and later, preferring
high-fidelity translation where available. Installed models run directly on iOS 26+.
Otherwise a small, attached SwiftUI translation-task anchor lets iOS request permission
to download its models. No third-party translation service or AI API key is used.
Translation text, original copies and enabled state stay in memory per document, including
private pages. They never enter tab sync or session files.

An isolated WebKit content world walks text and accessible labels, preserves whitespace,
and translates batches of at most 48 strings / approximately 10,000 characters. It does
not replace HTML or touch URLs, input values, scripts, code, editable text, explicit English
subtrees or `translate="no"` / `notranslate` opt-outs. Open shadow trees and subframes
participate. Dynamic additions and site-provided text updates queue more work. Disabling
restores only text still owned by the translation, preserving newer website edits.
Navigation resets the state, removed frames are ignored, and revision/document checks
reject late model replies after a toggle, close or navigation. Direction and language
attributes are temporarily changed to English/LTR and restored with the original text.

Run `-RisePageTranslationAudit` for real WebKit detection, icon placement and toggling,
restoration, links/forms, editable/code exclusions, shadow DOM, subframes, live updates,
large batches, cancellation, model errors, navigation and per-page isolation. Simulator
tests replace only the translation model with deterministic results; Apple's actual
language downloads and model output require an iOS device.

Apple API: https://developer.apple.com/documentation/translation/translating-text-within-your-app
