#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Chromium's browser process inside Rise: started once, before any page.
/// Ad and tracker blocking for every Chromium page, from Brave's adblock engine built with the
/// filter lists WebKit's rules come from. Requests go out unchecked until the lists are loaded.
@interface RCAdBlock : NSObject
/// Whether this build has it.
@property (class, readonly) BOOL available;
/// Whether requests are checked; off lets everything through.
@property (class) BOOL enabled;
/// Loads the lists, off the main thread.
+ (void)load;
/// Selectors to hide on a document at `url`; given the class and id names the document uses,
/// the general selectors for those names instead.
+ (NSArray<NSString *> *)hiddenSelectorsForURL:(NSURL *)url
                                       classes:(nullable NSArray<NSString *> *)classes
                                           ids:(nullable NSArray<NSString *> *)ids;
@end

@interface RCEngine : NSObject
/// The default search engine chosen in Chrome's settings (rise://settings), by name; nil if none.
+ (nullable NSString *)defaultSearchName;
/// Where a search for `terms` goes with that engine; nil if none.
+ (nullable NSURL *)searchURLForTerms:(NSString *)terms;
/// Loads the Chromium framework from the app bundle and starts it, keeping website data in
/// `cachePath`. Call on the main thread after `RCApplication.sharedApplication`, before the
/// run loop starts. Returns NO if Chromium couldn't start.
///
/// Chromium encrypts cookies and saved data with a key it keeps in the Keychain, in Rise's own
/// item ("Rise Safe Storage"). A throwaway profile, such as a test's, passes `keychain` NO: its
/// key is made up in memory and the Keychain is never asked, so it can't prompt for a password.
+ (BOOL)startWithCachePath:(NSString *)cachePath keychain:(BOOL)keychain;
@property (class, readonly) BOOL isRunning;
/// Stops Chromium; call as the app terminates.
+ (void)shutdown;
@end

/// The application class Chromium needs: it tells Chromium when AppKit is delivering an event.
@interface RCApplication : NSApplication
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
@interface RCFrame : NSObject
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
@interface RCDownload : NSObject
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
};

@class RCBrowserView;
@protocol RCBrowserViewDelegate <NSObject>
/// The page's address, title, loading state or history changed.
- (void)browserViewDidChange:(RCBrowserView *)browserView;
@optional
/// The pointer moved onto a link, or off one (nil).
- (void)browserView:(RCBrowserView *)browserView didHoverLink:(nullable NSURL *)url;
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
/// "Open Link in Peek" from the page's context menu.
- (void)browserView:(RCBrowserView *)browserView openLinkInPeek:(NSURL *)url;
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
@end

/// A page drawn by Chromium, filling this view. Rise lays it out, clips and animates it like
/// any other view.
@interface RCBrowserView : NSView
- (instancetype)initWithFrame:(NSRect)frame URL:(nullable NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, weak, nullable) id<RCBrowserViewDelegate> delegate;
@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
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
/// The back/forward history, with scroll positions and forms, for restoring at the next launch.
@property (nonatomic, readonly, nullable) NSData *navigationState;
/// Gives a page that hasn't loaded anything that history and loads its current entry, or loads
/// `fallback` if it can't use it.
- (void)restoreNavigationState:(NSData *)state fallback:(NSURL *)fallback;
/// The link under the pointer.
@property (nonatomic, readonly, nullable) NSURL *hoveredURL;
/// Under something else, such as a Peek: the page takes no hover and sets no cursor, though
/// mouse tracking would otherwise reach it through whatever covers it.
@property (nonatomic) BOOL covered;
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
- (void)setAudioMuted:(BOOL)muted;
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
/// The page's live picture, `rect` of it (in this view's coordinates), for showing elsewhere in
/// the window, as a Peek's card does on its way to and from its link: Chromium draws into it as
/// into the page, with nothing copied. Nil until the page has drawn. Scale it with a transform.
- (nullable CALayer *)liveLayerShowing:(NSRect)rect;
/// A picture of what the page shows now, the size of this view.
- (void)snapshotWithCompletion:(void (^)(NSImage *_Nullable image))completion;
/// Closes the page for good; the view shows nothing after.
- (void)close;
@end

NS_ASSUME_NONNULL_END
