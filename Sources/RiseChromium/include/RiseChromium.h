#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// What the engine's framework offers Rise, where the engine is a framework (Rise's fork).
#ifndef RC_EXPORT
#define RC_EXPORT
#endif

/// Ad blocking for every Chromium page: uBlock Origin, which Rise carries in its Resources and
/// Chrome loads as one of its own extensions.
RC_EXPORT @interface RCAdBlock : NSObject
/// Whether uBlock Origin is loaded; off unloads it, and every page's requests go through.
@property (class) BOOL enabled;
/// Sets `enabled`; `completion` once uBlock Origin is loaded or unloaded to match, on the main thread.
+ (void)setEnabled:(BOOL)enabled completion:(nullable void (^)(void))completion;
@end

/// Chromium's browser process inside Rise: started once, before any page.
RC_EXPORT @interface RCEngine : NSObject
/// The default search engine chosen in Chrome's settings (rise://settings), by name; nil if none.
+ (nullable NSString *)defaultSearchName;
/// Where a search for `terms` goes with that engine; nil if none.
+ (nullable NSURL *)searchURLForTerms:(NSString *)terms;
/// Loads the Chromium framework from the app bundle and starts it, keeping website data in
/// `cachePath`. Call on the main thread after `RCApplication.sharedApplication`, before the
/// run loop starts. Returns NO if Chromium couldn't start.
///
/// Chromium encrypts cookies and saved data with a key it keeps in the Keychain: in Chromium's
/// item ("Chromium Safe Storage"), or the one set with `setKeychainService:account:`. A throwaway
/// profile, such as a test's, passes `keychain` NO: its key is made up in memory and the
/// Keychain is never asked, so it can't prompt for a password.
+ (BOOL)startWithCachePath:(NSString *)cachePath keychain:(BOOL)keychain;
/// The Keychain item to keep that key in, as Chrome keeps its in "Chrome Safe Storage". Call
/// before `startWithCachePath:keychain:`.
+ (void)setKeychainService:(NSString *)service account:(NSString *)account;
@property (class, readonly) BOOL isRunning;
/// Whether `origin` (`scheme://host:port`) may show notifications, as Rise's site settings
/// say: allowed (1), blocked (-1), or to ask (0), forgetting what Chrome kept. Chrome shows a
/// site's notifications itself, in Notification Centre as Rise's, so it needs Rise's choices.
/// Before Chromium starts, this waits for it.
+ (void)setNotificationPermission:(NSInteger)permission forOrigin:(NSString *)origin;
/// Whether sites without a choice may ask to show notifications (YES) or are refused (NO).
+ (void)setNotificationsAsk:(BOOL)ask;
/// Stops Chromium; call as the app terminates.
+ (void)shutdown;
@end

/// The application class Chromium needs: it tells Chromium when AppKit is delivering an event.
// The engine's own application class, where it has one (Chrome's, on Rise's fork).
#ifndef RC_APPLICATION_SUPERCLASS
#define RC_APPLICATION_SUPERCLASS NSApplication
#endif
RC_EXPORT @interface RCApplication : RC_APPLICATION_SUPERCLASS
@end

/// Where a page asks for a link to open.
typedef NS_ENUM(NSInteger, RCOpenDisposition) {
  RCOpenDispositionForegroundTab,
  RCOpenDispositionBackgroundTab,
  RCOpenDispositionWindow,
  RCOpenDispositionPopup,
};

/// A frame a Rise script posted from, to run scripts in again: Chromium's DevTools session for
/// its process (empty for the page's own) and the script's execution context there.
RC_EXPORT @interface RCFrame : NSObject
@property (nonatomic, readonly) NSString *session;
@property (nonatomic, readonly) NSInteger context;
@property (nonatomic, readonly) BOOL isMain;
/// As the frame reports it: "https://example.com", or "null" for an opaque origin.
@property (nonatomic, readonly) NSString *origin;
@end

/// A file the page is downloading.
typedef NS_ENUM(NSInteger, RCDownloadState) {
  RCDownloadStateDownloading,
  RCDownloadStatePaused,
  RCDownloadStateFinished,
  RCDownloadStateCancelled,
  RCDownloadStateFailed,
};
RC_EXPORT @interface RCDownload : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) RCDownloadState state;
@property (nonatomic, readonly) int64_t receivedBytes;
/// -1 while unknown.
@property (nonatomic, readonly) int64_t totalBytes;
/// Called on the main thread whenever the state or the byte counts change.
@property (nonatomic, copy, nullable) void (^onUpdate)(RCDownload *download);
- (void)pause;
- (void)resume;
- (void)cancel;
@end

/// How the page is going somewhere.
typedef NS_ENUM(NSInteger, RCNavigationKind) {
  RCNavigationKindNewPage,
  RCNavigationKindHistory,
  RCNavigationKindReload,
};

/// What a page asks permission for.
typedef NS_OPTIONS(NSUInteger, RCPermission) {
  RCPermissionCamera = 1 << 0,
  RCPermissionMicrophone = 1 << 1,
  RCPermissionLocation = 1 << 2,
  /// Showing notifications, which once allowed Chrome keeps for the site, as it must to show
  /// them later, from the site's service worker too.
  RCPermissionNotifications = 1 << 3,
};

/// A dialog a page asks for: `alert()`, `confirm()`, `prompt()`, or, leaving or reloading a page
/// with changes it hasn't saved, whether to.
typedef NS_ENUM(NSInteger, RCDialogKind) {
  RCDialogKindAlert,
  RCDialogKindConfirm,
  RCDialogKindPrompt,
  RCDialogKindLeave,
  RCDialogKindReload,
};

/// What a page's file chooser picks.
typedef NS_ENUM(NSInteger, RCFileChooserMode) {
  RCFileChooserModeOpen,
  RCFileChooserModeOpenMultiple,
  RCFileChooserModeOpenFolder,
  RCFileChooserModeSave,
};

/// What was right-clicked as media.
typedef NS_ENUM(NSInteger, RCMediaKind) {
  RCMediaKindNone,
  RCMediaKindImage,
  RCMediaKindVideo,
  RCMediaKindAudio,
};

/// What an editable field right-clicked in can do.
typedef NS_OPTIONS(NSUInteger, RCEditFlags) {
  RCEditFlagsCanUndo = 1 << 0,
  RCEditFlagsCanRedo = 1 << 1,
  RCEditFlagsCanCut = 1 << 2,
  RCEditFlagsCanCopy = 1 << 3,
  RCEditFlagsCanPaste = 1 << 4,
  RCEditFlagsCanDelete = 1 << 5,
  RCEditFlagsCanSelectAll = 1 << 6,
};

typedef NS_ENUM(NSInteger, RCEditCommand) {
  RCEditCommandUndo,
  RCEditCommandRedo,
  RCEditCommandCut,
  RCEditCommandCopy,
  RCEditCommandPaste,
  RCEditCommandPasteAndMatchStyle,
  RCEditCommandDelete,
  RCEditCommandSelectAll,
};

/// An extension's entry in the page menu (chrome.contextMenus), as Chrome would show it for the
/// click: an extension with several is one entry, its name, holding them. Also the page's own
/// entries, as DevTools gives for its menus (see `customItems`).
RC_EXPORT @interface RCExtensionMenuItem : NSObject
/// Empty for a separator.
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) BOOL separator;
@property (nonatomic, readonly) BOOL enabled;
/// A checkbox or radio entry that's on.
@property (nonatomic, readonly) BOOL checked;
/// The extension's icon, on an extension's own entry.
@property (nonatomic, readonly, nullable) NSImage *icon;
/// What a submenu holds; empty for an entry.
@property (nonatomic, readonly) NSArray<RCExtensionMenuItem *> *children;
- (instancetype)init NS_UNAVAILABLE;
/// Tells the extension, or the page, it was chosen.
- (void)perform;
@end

/// What a right-click in a page was on, for Rise to build its menu from, and what that menu can
/// do there. Actions apply to the frame clicked in.
RC_EXPORT @interface RCContextMenu : NSObject
/// Where, in the page's view, from its top left.
@property (nonatomic, readonly) NSPoint point;
@property (nonatomic, readonly, nullable) NSURL *linkURL;
/// The image, video or audio's address.
@property (nonatomic, readonly, nullable) NSURL *sourceURL;
@property (nonatomic, readonly) RCMediaKind mediaKind;
/// Whether the image's picture is there to copy.
@property (nonatomic, readonly) BOOL hasImageContents;
@property (nonatomic, readonly) NSString *selectionText;
@property (nonatomic, readonly) BOOL editable;
@property (nonatomic, readonly) RCEditFlags editFlags;
/// The misspelled word clicked, and the spellchecker's suggestions for it.
@property (nonatomic, readonly) NSString *misspelledWord;
@property (nonatomic, readonly) NSArray<NSString *> *suggestions;
- (instancetype)init NS_UNAVAILABLE;
- (void)perform:(RCEditCommand)command;
- (void)replaceMisspellingWith:(NSString *)word;
/// Adds the misspelled word to the spelling dictionary.
- (void)learnMisspelledWord;
- (void)copyImage;
/// Saves a link or media source in the clicked document's context. Does nothing
/// once that document has navigated away or closed.
- (void)downloadURL:(NSURL *)url NS_SWIFT_NAME(download(_:));
/// Shows the dictionary's definition of the selection, at it.
- (void)lookUp;
/// Has the page's DevTools select the element clicked, once they're attached if they aren't yet.
- (void)inspect;
/// Prints as Chrome's menu does: an image or video clicked on its own, or else the page, or its
/// selection when there is one, in Chrome's print preview.
- (void)printPage;
/// Extensions' entries for what was clicked.
@property (nonatomic, readonly) NSArray<RCExtensionMenuItem *> *extensionItems;
/// The page's own entries, as DevTools gives for every menu it shows (its tabs' overflow, its
/// toolbars' menus, a node's or a request's right-click): when there are any, they're the menu,
/// as in Chrome. Call `closed` once that menu is gone, chosen from or not.
@property (nonatomic, readonly) NSArray<RCExtensionMenuItem *> *customItems;
/// Tells the page its menu closed, after any entry chosen was performed.
- (void)closed;
@end

@class RCBrowserView;
@protocol RCBrowserViewDelegate <NSObject>
/// The page's address, title, loading state or history changed.
- (void)browserViewDidChange:(RCBrowserView *)browserView;
@optional
/// The pointer moved onto a link, or off one (nil).
- (void)browserView:(RCBrowserView *)browserView didHoverLink:(nullable NSURL *)url;
/// The page used the key press `-watchNextKeyPress` was asked about, as its keydown handler did
/// or its editing did. `keyCode` is the press's `NSEvent.keyCode`.
- (void)browserView:(RCBrowserView *)browserView pageUsedKeyCode:(unsigned short)keyCode;
/// The page didn't use a key press, which goes to the menu bar next. Return YES to take it first.
- (BOOL)browserView:(RCBrowserView *)browserView handleUnusedKey:(NSEvent *)event;
/// The page wants `url` somewhere other than itself, a new tab or window. Return YES once
/// Rise has opened it; NO lets it open in this page instead.
- (BOOL)browserView:(RCBrowserView *)browserView openURL:(NSURL *)url disposition:(RCOpenDisposition)disposition
        userGesture:(BOOL)userGesture;
/// A window the page opens itself, by script or a link to a new window, made in `popup` with this
/// page as its opener, so the two can still talk (as sign-ins and Gmail's popped-out emails
/// need). Return YES once Rise has put `popup` somewhere; NO opens `url` as
/// `browserView:openURL:disposition:userGesture:` does instead.
- (BOOL)browserView:(RCBrowserView *)browserView adoptPopup:(RCBrowserView *)popup url:(NSURL *)url
        userGesture:(BOOL)userGesture;
/// A Rise script posted `body` to `handler`. `reply` is set for handlers added with replies,
/// and must be called once.
- (void)browserView:(RCBrowserView *)browserView
    didReceiveMessage:(id)body
              handler:(NSString *)handler
                frame:(RCFrame *)frame
                reply:(nullable void (^)(id _Nullable value, NSString *_Nullable error))reply;
/// The page wants to save a file named `suggestedName`: return where, or nil not to.
- (nullable NSURL *)browserView:(RCBrowserView *)browserView
         destinationForDownload:(RCDownload *)download
                  suggestedName:(NSString *)suggestedName;
/// `origin` asks for `permissions`; call `decide` once with those allowed (none to deny).
- (void)browserView:(RCBrowserView *)browserView
    requestPermissions:(RCPermission)permissions
                origin:(NSString *)origin
                decide:(void (^)(RCPermission allowed))decide;
/// A permission request was withdrawn, as by navigating away, before it was decided.
- (void)browserViewDidWithdrawPermissionRequest:(RCBrowserView *)browserView;
/// The page is about to go somewhere, before its request goes out.
- (void)browserView:(RCBrowserView *)browserView willNavigate:(RCNavigationKind)kind;
/// The page has finished loading.
- (void)browserViewDidFinishLoad:(RCBrowserView *)browserView;
/// The page failed to load `url`; `code` is Chromium's network error.
- (void)browserView:(RCBrowserView *)browserView
    didFailLoadWithCode:(NSInteger)code
            description:(NSString *)description
                    url:(nullable NSURL *)url;
/// The page's renderer process ended; it shows nothing until it's loaded again.
- (void)browserViewDidCrash:(RCBrowserView *)browserView;
/// A link for another app, such as mailto:, which the page doesn't open itself.
- (void)browserView:(RCBrowserView *)browserView openInOtherApp:(NSURL *)url;
/// The page is closing without Rise having asked, as when an extension closes its tab.
- (void)browserViewDidRequestClose:(RCBrowserView *)browserView;
/// DevTools for another page lay it out at `bounds`, in points from the top left of their
/// toolbox: a page they open with window.open (device_mode_emulation_frame.html), which Rise
/// shows in the inspected page's place, under it, as Chrome does. Their device mode shows its
/// toolbar and rulers there, around the page; otherwise the page fills it, from the origin.
- (void)browserView:(RCBrowserView *)browserView setInspectedPageBounds:(NSRect)bounds;
/// A site, at `host`, asks for a certificate to identify the person (TLS client authentication):
/// `identities` are the keychain's that suit it, as SecIdentityRefs. Call `completion` once with
/// the index of the one chosen, or -1 to go on without one; Chromium keeps either answer for the
/// site until it quits, as from its own chooser.
- (void)browserView:(RCBrowserView *)browserView
    chooseClientCertificate:(NSArray *)identities
                       host:(NSString *)host
                 completion:(void (^)(NSInteger index))completion;
/// The site's request went away (it navigated or closed) before a certificate was chosen: close
/// the chooser without calling its completion.
- (void)browserViewDidCancelClientCertificate:(RCBrowserView *)browserView;
/// The page was right-clicked; Rise shows its menu for `menu`.
- (void)browserView:(RCBrowserView *)browserView
    showContextMenu:(RCContextMenu *)menu NS_SWIFT_NAME(browserView(_:showContextMenu:));
/// An extension popup's page has a new size, as Chrome sizes popups to what they show (see
/// `sizesExtensionPopups`), in points.
- (void)browserView:(RCBrowserView *)browserView didChangePreferredSize:(NSSize)size;
/// An installed extension asks to show its action popup for this active tab. Call `completion`
/// once after showing it, or NO if the window cannot show it. Chrome validates the request first.
- (void)browserView:(RCBrowserView *)browserView
    showExtensionPopup:(NSURL *)url
           extensionID:(NSString *)extensionID
            completion:(void (^)(BOOL shown))completion;
/// The page, at `origin`, asks for a dialog; call `completion` once, with whether it was accepted
/// and, for a prompt, the text.
- (void)browserView:(RCBrowserView *)browserView
          runDialog:(RCDialogKind)kind
            message:(NSString *)message
        defaultText:(NSString *)defaultText
             origin:(nullable NSURL *)origin
         completion:(void (^)(BOOL accepted, NSString *_Nullable text))completion;
/// The page's dialog is no longer wanted, as when it navigated away: close it without completing.
- (void)browserViewDidCancelDialog:(RCBrowserView *)browserView;
/// The page asks for files; call `completion` once, with those chosen or nil. `extensions`, if
/// any, are the kinds of file it takes, such as "png".
- (void)browserView:(RCBrowserView *)browserView
        chooseFiles:(RCFileChooserMode)mode
              title:(NSString *)title
        defaultPath:(NSString *)defaultPath
         extensions:(NSArray<NSString *> *)extensions
         completion:(void (^)(NSArray<NSURL *> *_Nullable urls))completion;
@end

/// A page drawn by Chromium, filling this view. Rise lays it out, clips and animates it like
/// any other view.
RC_EXPORT @interface RCBrowserView : NSView
- (instancetype)initWithFrame:(NSRect)frame URL:(nullable NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, weak, nullable) id<RCBrowserViewDelegate> delegate;
/// Reports it to the delegate if the page uses the next key press it gets
/// (`browserView:pageUsedKeyCode:`). One that isn't used comes to `browserView:handleUnusedKey:`.
- (void)watchNextKeyPress;
@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
/// Navigation loading state for browser UI. Late subframe loads on a finished page do not
/// restart the tab's progress or turn Reload back into Stop.
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) double progress;
/// Whether the page makes sound now.
@property (nonatomic, readonly) BOOL audible;
/// Whether the page shows an element full screen, through the Fullscreen API; Rise makes the
/// view fill the screen while it does.
@property (nonatomic, readonly) BOOL fullscreen;
/// Takes the page out of full screen, as Escape does.
- (void)exitFullscreen;
/// Loads without running the page's scripts, as a page loaded out of sight only to warm the
/// cache does. Set before the view's first turn of the run loop.
@property (nonatomic) BOOL scriptsDisabled;
/// A Chrome extension's popup, as extensions see it (a "popup" view, not a tab). Set it before
/// the page loads.
@property (nonatomic) BOOL extensionPopup;
/// Whether the engine sizes an extension popup's page to what it shows, from 25 by 25 to 800 by
/// 600 points, as Chrome does, telling the delegate; if not, Rise measures the page.
@property (class, nonatomic, readonly) BOOL sizesExtensionPopups;
/// The back/forward history, with scroll positions and forms, for restoring at the next launch.
@property (nonatomic, readonly, nullable) NSData *navigationState;
/// Gives a page that hasn't loaded anything that history and loads its current entry, or loads
/// `fallback` if it can't use it.
- (void)restoreNavigationState:(NSData *)state fallback:(NSURL *)fallback;
/// HTTP(S) URL/title entries and the current index, for history shared with another engine.
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, id> *navigationHistory;
/// Restores portable history on an empty page; only the current destination is loaded.
- (BOOL)restoreNavigationHistory:(NSDictionary<NSString *, id> *)history fallback:(NSURL *)fallback;
/// The link under the pointer.
@property (nonatomic, readonly, nullable) NSURL *hoveredURL;
/// Under something else, such as a Peek: the page takes no hover and sets no cursor, though
/// mouse tracking would otherwise reach it through whatever covers it.
@property (nonatomic) BOOL covered;
/// Runs as a page on screen, drawing and taking input, even out of sight or in a covered window,
/// as a page being captured does: while Rise's agent uses it. Off, Chromium hides a page out of
/// sight and stops drawing it, and input sent to it then never arrives.
@property (nonatomic) BOOL keepsVisible;
/// The page's own view, which takes the keyboard: focusing the page is making it first
/// responder, as Chrome does, not this view.
@property (nonatomic, readonly, nullable) NSView *focusView;
/// Page zoom as a factor, 1 for 100%.
@property (nonatomic) double zoom;
/// The color shown where the page hasn't painted yet.
@property (nonatomic, copy) NSColor *pageBackgroundColor;
/// Whether the page should look dark, as its `prefers-color-scheme` reports, whatever macOS's
/// own appearance; nil follows macOS.
@property (nonatomic, copy, nullable) NSNumber *prefersDark;
- (void)loadURL:(NSURL *)url NS_SWIFT_NAME(open(_:));
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
/// Whether the page can print now, as Chrome's File > Print checks: printing is on, the page
/// hasn't crashed, no dialog of its own (print preview, say) is over it, and it doesn't forbid it,
/// as a PDF without the right to print does.
@property (nonatomic, readonly) BOOL canPrint;
/// Prints the page as Chrome's File > Print does, in Chrome's print preview over the page: the
/// frame with focus, or the PDF a PDF viewer shows rather than the viewer.
- (void)printPage;
/// Prints with the system's print dialog, as Chrome's Print Using System Dialog does, from the
/// page or its print preview.
- (void)printPageUsingSystemDialog;
- (void)setAudioMuted:(BOOL)muted;
/// Whether Chromium has the page's sound muted.
@property (nonatomic, readonly) BOOL isAudioMuted;
/// Downloads `url` as the page would, into Rise's downloads.
- (void)downloadURL:(NSURL *)url NS_SWIFT_NAME(download(_:));
/// Runs `functionBody` as the body of an async function with `arguments` as its parameters,
/// in the isolated script world `world`, which the page's own scripts can't see. Completes
/// with the returned value, as JSON allows, or nil if it threw or the page went away.
- (void)evaluateFunctionBody:(NSString *)functionBody
                   arguments:(NSDictionary<NSString *, id> *)arguments
                       world:(NSString *)world
                  completion:(void (^)(id _Nullable result))completion;
/// Runs `source` in `world` at the start of every document this page loads from now on,
/// and in the current one.
- (void)addScriptToEveryDocument:(NSString *)source world:(NSString *)world;
/// Lets Rise scripts in `world` (nil: the page's own) post to `name`, as
/// `riseHandlers.<name>.postMessage(body)`, which returns a promise of the reply when `replies`.
/// Add handlers before the scripts that use them.
- (void)addMessageHandler:(NSString *)name world:(nullable NSString *)world replies:(BOOL)replies;
/// Runs `source` at the start of every document, in every frame (or only the main one), in
/// `world` (nil: the page's own), with `riseHandlers` holding the message handlers it's given.
/// Frames of other sites, in processes of their own, run it too.
- (void)addUserScript:(NSString *)source
                world:(nullable NSString *)world
        mainFrameOnly:(BOOL)mainFrameOnly
             handlers:(NSArray<NSString *> *)handlers;
/// Runs `expression` in the page as a console does, statements, `let` and `await` included,
/// with the value of the last; or the error it threw.
/// Sends a DevTools protocol command to the page, as DevTools would: `completion` hears its
/// result, or nil if it failed.
- (void)devTools:(NSString *)method
          params:(NSDictionary<NSString *, id> *)params
      completion:(void (^)(NSDictionary<NSString *, id> *_Nullable result))completion
    NS_SWIFT_NAME(devTools(_:params:completion:));
- (void)evaluateConsoleExpression:(NSString *)expression
                       completion:(void (^)(id _Nullable value, NSString *_Nullable error))completion;
/// A page showing Chromium's DevTools for this one, opened on the Elements panel. It inspects
/// this page from when its front end loads; `close` it when it's done.
- (RCBrowserView *)makeDevToolsView;
/// Stops running user scripts whose source starts with `prefix` on documents to come.
- (void)removeUserScriptsWithPrefix:(NSString *)prefix;
/// As `evaluateFunctionBody:arguments:world:completion:`, in `frame` (nil: the main one) and
/// `world` (nil: the page's own), reporting why it failed.
- (void)evaluateFunctionBody:(NSString *)functionBody
                   arguments:(NSDictionary<NSString *, id> *)arguments
                       frame:(nullable RCFrame *)frame
                       world:(nullable NSString *)world
                  completion:(void (^)(id _Nullable result, NSString *_Nullable error))completion;
/// Background automation uses NO: inspecting or accepting consent must not synthesize a
/// trusted user activation. User-invoked page tools keep the overload above.
- (void)evaluateFunctionBody:(NSString *)functionBody
                   arguments:(NSDictionary<NSString *, id> *)arguments
                       frame:(nullable RCFrame *)frame
                       world:(nullable NSString *)world
                 userGesture:(BOOL)userGesture
                  completion:(void (^)(id _Nullable result, NSString *_Nullable error))completion;
/// The page's live picture, `rect` of it (in this view's coordinates), for showing elsewhere in
/// the window, as a Peek's card does on its way to and from its link: Chromium draws into it as
/// into the page, with nothing copied. Nil until the page has drawn. Scale it with a transform.
- (nullable CALayer *)liveLayerShowing:(NSRect)rect;
/// A picture of what the page shows now, the size of this view.
- (void)snapshotWithCompletion:(void (^)(NSImage *_Nullable image))completion;
/// What the page shows now in `rect` (points from its top left), scaled to `size` pixels as it's
/// copied: cheap enough to look at a strip of the page several times a second. Nil while it isn't
/// drawing, as when hidden. `completion` may come on any thread.
- (void)snapshotRect:(NSRect)rect size:(NSSize)size completion:(void (^)(NSImage *_Nullable image))completion;
/// Closes the page for good; the view shows nothing after.
- (void)close;
@end

/// What Chrome extensions ask of a Rise window: tabs opened, brought forward, moved, pinned or
/// closed. Called on the main thread.
@protocol RCTabStripDelegate <NSObject>
/// Opens `url` in a new tab at `index` (-1: the end), in front if `active`; returns its page,
/// once it's among the window's tabs, or nil not to open one.
- (nullable RCBrowserView *)tabStripOpenTabWithURL:(NSURL *)url index:(NSInteger)index active:(BOOL)active;
- (void)tabStripActivateTab:(RCBrowserView *)tab;
- (void)tabStripCloseTab:(RCBrowserView *)tab;
- (void)tabStripMoveTab:(RCBrowserView *)tab toIndex:(NSInteger)index;
- (void)tabStripSetTab:(RCBrowserView *)tab pinned:(BOOL)pinned;
- (void)tabStripActivateWindow;
@optional
/// A tab an extension opened in the window, as tabs.create does, its page already made: Rise puts
/// it among the window's tabs at `index` (-1: the end), in front if `active`. NO closes it.
- (BOOL)tabStripAdoptTab:(RCBrowserView *)tab index:(NSInteger)index active:(BOOL)active;
@end

/// A Rise window as Chrome extensions see it: a browser window holding its tabs, which the tabs
/// and windows APIs list and act on.
RC_EXPORT @interface RCTabStrip : NSObject
- (instancetype)initWithDelegate:(id<RCTabStripDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// The window's id, as extensions see it.
@property (nonatomic, readonly) NSInteger windowID;
/// The window's tabs in order, the first `pinnedCount` pinned, the one at `activeIndex` in front
/// (-1: none). Pages still being made join once they exist.
- (void)setTabs:(NSArray<RCBrowserView *> *)tabs pinnedCount:(NSInteger)pinnedCount activeIndex:(NSInteger)activeIndex;
/// Whether it's the window in front.
@property (nonatomic) BOOL active;
/// Its frame on screen, in AppKit's coordinates.
@property (nonatomic) NSRect frame;
/// Removes the window, as when it closes.
- (void)close;
@end

/// A Chrome extension's toolbar button. Values for a tab take its page; nil gives the defaults.
RC_EXPORT @interface RCExtensionAction : NSObject
@property (nonatomic, readonly) NSString *extensionID;
@property (nonatomic, readonly) NSString *name;
- (NSString *)titleForTab:(nullable RCBrowserView *)tab;
/// Empty for no badge.
- (NSString *)badgeTextForTab:(nullable RCBrowserView *)tab;
- (NSColor *)badgeColorForTab:(nullable RCBrowserView *)tab;
/// Nil while it's still loading; observers hear when it's ready.
- (nullable NSImage *)iconForTab:(nullable RCBrowserView *)tab;
- (BOOL)isEnabledForTab:(nullable RCBrowserView *)tab;
/// Clicks it in `tab`, giving the extension the tab if it asks for the active one: the popup's
/// address for Rise to show, or nil if the extension took the click itself.
- (nullable NSURL *)clickInTab:(RCBrowserView *)tab;
@end

/// A keyboard shortcut an extension set (chrome.commands).
RC_EXPORT @interface RCExtensionShortcut : NSObject
@property (nonatomic, readonly) NSString *extensionID;
/// Whether it clicks the extension's button, which Rise does as for a click, opening any popup.
@property (nonatomic, readonly) BOOL clicksButton;
- (instancetype)init NS_UNAVAILABLE;
/// Tells the extension, for `tab` (the one in front).
- (void)runInTab:(nullable RCBrowserView *)tab;
@end

/// The toolbar buttons of the extensions installed in Rise's profile.
RC_EXPORT @interface RCExtensions : NSObject
@property (class, readonly) NSArray<RCExtensionAction *> *actions;
/// Calls `changed` on the main thread whenever buttons are added, removed or change, until the
/// returned object goes away.
+ (id)observeActions:(void (^)(void))changed;
/// The extension shortcut a key press is, if it's one.
+ (nullable RCExtensionShortcut *)shortcutForEvent:(NSEvent *)event;
/// Installs the Chrome Web Store's extension `extensionID`, after the install prompt asks;
/// `completion` hears how it went.
+ (void)installFromWebStore:(NSString *)extensionID
                 completion:(nullable void (^)(BOOL success, NSString *_Nullable error))completion;
/// Asks the person before any extension is installed, in place of Chrome's dialog: `prompt` shows
/// the title (such as “Add uBlock Origin Lite?”), the icon and what it will be able to do, and calls
/// `answer` once. Nil gives Chrome's dialog back.
+ (void)setInstallPrompt:(nullable void (^)(NSString *title, NSImage *_Nullable icon, NSArray<NSString *> *permissions,
                                            NSString *acceptLabel, void (^answer)(BOOL accept)))prompt;
/// Asks the person before an extension is removed, in place of Chrome's dialog: `prompt` shows the
/// title (such as “Remove "Dark Reader"?”), the icon and the remove button's label, and calls
/// `answer` once. Nil gives Chrome's dialog back.
+ (void)setUninstallPrompt:(nullable void (^)(NSString *title, NSImage *_Nullable icon, NSString *acceptLabel,
                                              void (^answer)(BOOL accept)))prompt;
@end

NS_ASSUME_NONNULL_END
