# Third-party notices

## Helium keyboard shortcut editor

The desktop shortcut editor's layout, styles, dialogs and search ranking adapt
Helium's `custom-keyboard-shortcuts-page.patch`, copyright 2026 The Helium Authors,
at revision `58261a24341935be831fa3b97d31c46232c81b59`.
Source: https://github.com/imputnet/helium/blob/58261a24341935be831fa3b97d31c46232c81b59/patches/helium/settings/custom-keyboard-shortcuts-page.patch

Licensed under GPL-3.0. The original source and license are retained in
`Engine/third_party/helium`; the complete license ships in
`Contents/Resources/Licenses/Helium-GPL-3.0.txt`.

## Cookie consent automation

Desktop and iOS bundle DuckDuckGo Autoconsent 16.52.0 (MPL-2.0), along with
tldts-core and tldts-experimental (MIT). Source, versions and copyright details
are in `CookieConsent/NOTICE.md`; complete licenses ship alongside the verified
rule assets in each app. Rise's shared acceptance-only integration and reproducible
build are in `scripts/ios-cookie-consent/`.

Source: https://github.com/duckduckgo/autoconsent/tree/39dba9ea267ce98037a4cec7fea38abfc50b3d3d

ShimmeringTextField.swift adapts the gradient mechanics of ElevenLabs UI’s Shimmering Text component.
Source: https://github.com/elevenlabs/ui

MIT License

Copyright (c) 2025 Eleven Labs Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Tabler Icons

ArchiveButton.swift, TablerIcon.swift, MenuIcons.swift, the iOS menu SVG assets and Playgrounds/download-flight.html draw icons from Tabler Icons (archive, paint roller, adjustments, link, link-copied, eye, inward diagonal arrows, input search, settings, ad, spy and cookie).
Source: https://github.com/tabler/tabler-icons

MIT License

Copyright (c) 2020-2026 Paweł Kuna

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Inter

Inter 4.1, the variable font in Assets/Fonts (bundled as Contents/Resources/Fonts): Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter). Licensed under the SIL Open Font License, Version 1.1; its complete license is in Assets/Fonts/Inter-LICENSE.txt, bundled beside the font.

## Ioskeley Mono

Ioskeley Mono 2.2.0 Regular, in Assets/Fonts (bundled as Contents/Resources/Fonts), for developer mode's address: Copyright (c) 2025, Ahmed Hatem (https://github.com/ahatem/IoskeleyMono). Licensed under the SIL Open Font License, Version 1.1; its complete license is in Assets/Fonts/IoskeleyMono-LICENSE.txt, bundled beside the font.

## Framework7 Icons

The address palette's search glyph (Sources/Rise/CenteredPaletteStyle.swift) is Framework7 Icons' `search`, as Kero (https://github.com/egoist/kero) uses it: Copyright (c) Vladimir Kharlampidi (https://framework7.io/icons/). Licensed under the MIT License: permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to including the copyright notice and this permission notice in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## Kero

The Rise theme's Mist wash (Sources/Rise/Chrome.swift), the Plain light theme's wash and window material, and its tabs' ring, shadow, hover and fades (Sources/Rise/PlainTabBackground.swift) follow Kero's theme.go, elevation.go and view.go: Copyright (c) 2026 EGOIST (https://github.com/egoist/kero). Licensed under the MIT License: permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to including the copyright notice and this permission notice in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## Blocking filter data

uBlock Origin: Copyright (C) Raymond Hill and contributors (https://github.com/gorhill/uBlock). The Mac app carries a release pinned in Engine/ublock.json, changed only by scripts/ublock.py: its manifest gains a key, and its tracker lists start off under GPL-3.0; its license is in the app at Contents/Resources/uBlock0.chromium/LICENSE.txt and in Filters/LICENSES/GPL-3.0.txt. Its filter lists keep their own licenses.

EasyList: The EasyList authors (https://easylist.to/). The filter data is distributed under GPL-3.0; its complete license is in Filters/LICENSES/GPL-3.0.txt. The iPhone app's original source snapshots, which include it, are in Filters/iOS/Sources/.

AdGuard SafariConverterLib 4.3.0 is used as a build-time conversion tool for the iPhone app's rules (GPL-3.0, https://github.com/AdguardTeam/SafariConverterLib); its binary is not bundled or linked into Rise.

## Torph text morphing

RiseCore/TorphText.swift and the iOS TorphTextView/TorphAnimation port the text-only
segmentation, word/character diff, FLIP, fades, grouped replacements and interrupted
size transitions of Torph (numbers:false). Source: https://github.com/lochie/torph
at d79a5aa63226acf97d49c3e34fafb2e85c07b026. MIT © 2025 Lochie Axon.
The complete MIT license ships in the iOS app as Torph-LICENSE.txt. Native word
segmentation uses ICU; changed words retain Swift grapheme clusters, and punctuation
fragments are flattened before character matching. Numeric rolling and web framework
adapters are outside this text-label port.

## Font Awesome

The iOS Open App Store toast uses the supplied square-up-right icon from
Font Awesome Solid by Dave Gandy (https://fontawesome.com/), licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Its SVG path is unchanged;
the display size and template color adapt to Rise's toast icons.

## Streamline

The iOS Open App Store toast uses the supplied App Store fallback icon from
Logos free icons by Streamline (https://www.streamlinehq.com/), licensed under
CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Its SVG path is unchanged;
the display size and template color adapt to Rise's toast icons.
