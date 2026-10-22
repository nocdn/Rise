# Image context menus on iOS

WebKit owns the image preview and Save to Photos, Copy, Share and image-analysis actions.
The app declares `NSPhotoLibraryAddUsageDescription` so saving can request add-only
Photos permission instead of being terminated by iOS for a missing purpose string.

`ImageContextMenus` observes image touches in an isolated WebKit content world. A plain
image of `currentSrc` reads the resource's own dimensions from WebKit's image cache,
avoiding CSS display sizes and the density correction applied to `srcset` images.
It works with data/blob images and open shadow roots without canvas access, CORS fetches
or copying browser cookies to another networking stack.

Linked images use `UIMenu(title:children:)` with WebKit's supplied actions. WebKit's public
menu delegate only runs for links; unlinked image menus read the image element's title.
The script temporarily appends the dimensions there, then restores the original value
when the menu closes. Ordinary taps restore it after a short timeout instead. The public
menu presentation callbacks keep the heading stable during image-analysis updates.
A website's subsequent title changes are preserved.

Run `-RiseImageContextMenuAudit` for resource/CSS and Retina dimensions, original title
restoration, website changes, blob/shadow images, broken images and menu action retention.
The audit ends on a fixture for a native long press and Save to Photos check. Verify that
the saved Photos asset has the dimensions shown in the menu.

Apple documentation: [Photos additions purpose string](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription),
[native menu title](https://developer.apple.com/documentation/uikit/uimenu/init(title:image:identifier:options:children:)).
