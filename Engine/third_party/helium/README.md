# Helium keyboard shortcut editor

The desktop keyboard shortcuts screen adapts Helium's editor from
[`imputnet/helium`](https://github.com/imputnet/helium), revision
`58261a24341935be831fa3b97d31c46232c81b59`.

`custom-keyboard-shortcuts-page.patch` is the unmodified upstream source snapshot.
The adapted layout, styles, dialogs and search ranking are carried by
`Engine/fork/patches/0028-helium-shortcut-editor.patch`. Rise uses its existing Lit
settings plugin and AppKit command registry instead of Helium's Mojo service.

Copyright 2026 The Helium Authors. Licensed under GPL-3.0; the full license is in
`LICENSE` and is bundled with Rise as `Licenses/Helium-GPL-3.0.txt`.
