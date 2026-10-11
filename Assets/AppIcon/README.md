# Shared app icon

`Original.png` is the unchanged 1254 × 1254 photo from Downloads. Both apps use
`Rise.icon`, the Icon Composer document containing a 1024 × 1024 version of that
artwork. The system applies its own platform mask; the source has no added corner
mask. Liquid Glass effects are disabled on the artwork to preserve the supplied design.

To regenerate the document's image from the original, from the repository root:

```sh
sips -z 1024 1024 Assets/AppIcon/Original.png --out Assets/AppIcon/Rise.icon/Assets/Rise.png
```

Xcode and `scripts/build.sh` compile the same document, including platform-specific
appearances and fallback icons for older operating systems. See Apple's
[app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
and [Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
