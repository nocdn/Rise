#import "RiseChromium.h"
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <crt_externs.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_download_handler.h"
#include "include/cef_permission_handler.h"
#include "include/wrapper/cef_library_loader.h"

static NSString *const RCContextReadyNotification = @"RCContextReady";

namespace {

CefScopedLibraryLoader *gLibrary = nullptr;
bool gRunning = false;
bool gMockKeychain = false;
bool gContextReady = false;

// Chromium's work runs on AppKit's own run loop, in every mode, so it keeps going while a
// menu tracks, a window resizes or Rise animates.
CFRunLoopTimerRef gPump = nullptr;
bool gInWork = false;
constexpr double kMaxPumpDelay = 1.0 / 30.0;

void SchedulePump(double delay) {
  if (gPump) CFRunLoopTimerSetNextFireDate(gPump, CFAbsoluteTimeGetCurrent() + delay);
}

void PumpWork() {
  // Never re-entered: a nested run loop inside Chromium's work comes back here.
  if (gInWork) {
    SchedulePump(0);
    return;
  }
  gInWork = true;
  CefDoMessageLoopWork();
  gInWork = false;
  // A slow heartbeat in case Chromium asks for nothing.
  CFAbsoluteTime next = CFRunLoopTimerGetNextFireDate(gPump), now = CFAbsoluteTimeGetCurrent();
  if (next <= now || next > now + kMaxPumpDelay) SchedulePump(kMaxPumpDelay);
}

class RiseApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    // Chromium's testing experiments stay off even in a build that forgets to say so.
    if (process_type.empty()) command_line->AppendSwitch("disable-field-trial-config");
    if (process_type.empty() && gMockKeychain) command_line->AppendSwitch("use-mock-keychain");
  }
  void OnContextInitialized() override {
    gContextReady = true;
    [NSNotificationCenter.defaultCenter postNotificationName:RCContextReadyNotification object:nil];
  }
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    double delay = delay_ms <= 0 ? 0 : std::min(kMaxPumpDelay, delay_ms / 1000.0);
    dispatch_async(dispatch_get_main_queue(), ^{ SchedulePump(delay); });
  }

 private:
  IMPLEMENT_REFCOUNTING(RiseApp);
};

}  // namespace

@interface RCBrowserView ()
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
- (void)updateURL:(NSURL *)url;
- (void)updateTitle:(NSString *)title;
- (void)updateProgress:(double)progress;
- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward;
- (void)updateHoveredURL:(nullable NSURL *)url;
- (BOOL)openURL:(NSURL *)url disposition:(RCOpenDisposition)disposition userGesture:(BOOL)gesture;
- (BOOL)canOpenInPeek;
- (void)openLinkInPeek:(NSURL *)url;
- (void)devToolsMessage:(NSData *)json;
- (nullable NSString *)destinationForDownload:(CefRefPtr<CefDownloadItem>)item suggestedName:(NSString *)name;
- (void)updateDownload:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
- (void)requestPermissions:(RCPermission)permissions origin:(NSString *)origin decide:(void (^)(RCPermission allowed))decide;
- (void)withdrawPermissionRequest;
- (void)updateAudible:(BOOL)audible;
@end

@interface RCFrame ()
- (instancetype)initWithSession:(NSString *)session context:(NSInteger)context main:(BOOL)main origin:(NSString *)origin;
@end

@implementation RCFrame
- (instancetype)initWithSession:(NSString *)session context:(NSInteger)context main:(BOOL)main origin:(NSString *)origin {
  if ((self = [super init])) {
    _session = session.copy;
    _context = context;
    _isMain = main;
    _origin = origin.copy;
  }
  return self;
}
@end

@implementation RCDownload {
  @public
  CefRefPtr<CefDownloadItemCallback> _callback;
  BOOL _cancelled;
}
- (void)updateFrom:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  if (callback) _callback = callback;
  _url = [NSURL URLWithString:[NSString stringWithUTF8String:item->GetURL().ToString().c_str()]] ?: _url;
  _receivedBytes = item->GetReceivedBytes();
  _totalBytes = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;
  if (item->IsComplete()) _state = RCDownloadStateFinished;
  else if (item->IsCanceled()) _state = _cancelled ? RCDownloadStateCancelled : RCDownloadStateFailed;
  else if (item->IsInterrupted()) _state = RCDownloadStateFailed;
  else if (item->IsPaused()) _state = RCDownloadStatePaused;
  else _state = RCDownloadStateDownloading;
  if (_onUpdate) _onUpdate(self);
}
- (void)pause {
  if (_callback) _callback->Pause();
}
- (void)resume {
  if (_callback) _callback->Resume();
}
- (void)cancel {
  _cancelled = YES;
  if (_callback) _callback->Cancel();
}
@end

namespace {

NSURL *URLFromString(const CefString &value) {
  NSString *text = [NSString stringWithUTF8String:value.ToString().c_str()];
  return text.length ? [NSURL URLWithString:text] : nil;
}

bool Disposition(cef_window_open_disposition_t disposition, RCOpenDisposition *result) {
  switch (disposition) {
    case CEF_WOD_NEW_FOREGROUND_TAB: *result = RCOpenDispositionForegroundTab; return true;
    case CEF_WOD_NEW_BACKGROUND_TAB: *result = RCOpenDispositionBackgroundTab; return true;
    case CEF_WOD_NEW_WINDOW: *result = RCOpenDispositionWindow; return true;
    case CEF_WOD_NEW_POPUP: *result = RCOpenDispositionPopup; return true;
    default: return false;
  }
}

constexpr int kOpenInPeekCommand = MENU_ID_USER_FIRST + 1;

class RiseClient : public CefClient,
                   public CefDisplayHandler,
                   public CefLoadHandler,
                   public CefLifeSpanHandler,
                   public CefRequestHandler,
                   public CefContextMenuHandler,
                   public CefDownloadHandler,
                   public CefPermissionHandler {
 public:
  explicit RiseClient(RCBrowserView *view) : view_(view) {}
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  // Files the page saves go where Rise says, into its own downloads list.
  bool CanDownload(CefRefPtr<CefBrowser>, const CefString &, const CefString &) override { return true; }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString &suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString *path = [view_ destinationForDownload:item
                                     suggestedName:[NSString stringWithUTF8String:suggested_name.ToString().c_str()]];
    if (!path) return false;
    callback->Continue(path.UTF8String, false);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    [view_ updateDownload:item callback:callback];
  }

  // Camera, microphone and location go through Rise's own prompt; the rest stay denied.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &origin,
                                      uint32_t requested, CefRefPtr<CefMediaAccessCallback> callback) override {
    if (requested & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
      callback->Cancel();
      return true;
    }
    RCPermission permissions = 0;
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) permissions |= RCPermissionCamera;
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) permissions |= RCPermissionMicrophone;
    if (!permissions) return false;
    [view_ requestPermissions:permissions
                       origin:[NSString stringWithUTF8String:origin.ToString().c_str()]
                       decide:^(RCPermission allowed) {
                         uint32_t granted = 0;
                         if (allowed & RCPermissionCamera) granted |= CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
                         if (allowed & RCPermissionMicrophone) granted |= CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
                         if (granted == requested) callback->Continue(granted);
                         else callback->Cancel();
                       }];
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &origin, uint32_t requested,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (requested != CEF_PERMISSION_TYPE_GEOLOCATION) {
      callback->Continue(CEF_PERMISSION_RESULT_DENY);
      return true;
    }
    [view_ requestPermissions:RCPermissionLocation
                       origin:[NSString stringWithUTF8String:origin.ToString().c_str()]
                       decide:^(RCPermission allowed) {
                         callback->Continue(allowed & RCPermissionLocation ? CEF_PERMISSION_RESULT_ACCEPT
                                                                           : CEF_PERMISSION_RESULT_DENY);
                       }];
    return true;
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, cef_permission_request_result_t result) override {
    if (result == CEF_PERMISSION_RESULT_IGNORE) [view_ withdrawPermissionRequest];
  }
  void OnAudibleChange(CefRefPtr<CefBrowser>, bool audible) override { [view_ updateAudible:audible]; }

  // Chromium's status bubble text is the hovered link; Rise shows its own pill instead.
  void OnStatusMessage(CefRefPtr<CefBrowser>, const CefString &value) override {
    [view_ updateHoveredURL:URLFromString(value)];
  }
  // ⌘-clicks and the like: Rise's own tabs take them.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &target_url,
                        cef_window_open_disposition_t target_disposition, bool user_gesture) override {
    RCOpenDisposition disposition;
    NSURL *url = URLFromString(target_url);
    return url && Disposition(target_disposition, &disposition) && [view_ openURL:url disposition:disposition userGesture:user_gesture];
  }
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    if (params->GetLinkUrl().empty() || ![view_ canOpenInPeek]) return;
    model->InsertItemAt(0, kOpenInPeekCommand, "Open Link in Peek");
    model->InsertSeparatorAt(1);
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                            int command_id, cef_event_flags_t) override {
    if (command_id != kOpenInPeekCommand) return false;
    if (NSURL *url = URLFromString(params->GetLinkUrl())) [view_ openLinkInPeek:url];
    return true;
  }

  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (!frame->IsMain()) return;
    NSString *text = [NSString stringWithUTF8String:url.ToString().c_str()];
    [view_ updateURL:text.length ? [NSURL URLWithString:text] : nil];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    [view_ updateTitle:[NSString stringWithUTF8String:title.ToString().c_str()]];
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    [view_ updateProgress:progress];
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading, bool canGoBack, bool canGoForward) override {
    [view_ updateLoading:isLoading back:canGoBack forward:canGoForward];
  }
  // A link or script opening a window goes to Rise's tabs; failing that, this page.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int, const CefString &target_url,
                     const CefString &, WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures &, CefWindowInfo &, CefRefPtr<CefClient> &, CefBrowserSettings &,
                     CefRefPtr<CefDictionaryValue> &, bool *) override {
    RCOpenDisposition disposition;
    if (!Disposition(target_disposition, &disposition)) disposition = RCOpenDispositionForegroundTab;
    NSURL *url = URLFromString(target_url);
    if (!url || ![view_ openURL:url disposition:disposition userGesture:user_gesture]) browser->GetMainFrame()->LoadURL(target_url);
    return true;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { [view_ browserCreated:browser]; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override { [view_ browserClosed]; }

 private:
  __weak RCBrowserView *view_;
  IMPLEMENT_REFCOUNTING(RiseClient);
};

// Answers to DevTools commands Rise sends the page, which stay inside the app: no port or
// remote debugging is involved.
class DevToolsReplies : public CefDevToolsMessageObserver {
 public:
  explicit DevToolsReplies(RCBrowserView *view) : view_(view) {}
  // Every reply and event, raw, since those of other processes' frames carry their session.
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void *message, size_t message_size) override {
    [view_ devToolsMessage:[NSData dataWithBytes:message length:message_size]];
    return true;
  }

 private:
  __weak RCBrowserView *view_;
  IMPLEMENT_REFCOUNTING(DevToolsReplies);
};

// The layer Chromium shows its GPU process's frames through, in the page's layers.
CALayer *ContentHost(CALayer *layer) {
  if ([NSStringFromClass(layer.class) isEqualToString:@"CALayerHost"]) return layer;
  for (CALayer *sublayer in layer.sublayers)
    if (CALayer *host = ContentHost(sublayer)) return host;
  return nil;
}

cef_color_t ARGB(NSColor *color) {
  NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.whiteColor;
  auto channel = [](CGFloat value) { return (uint32_t)std::lround(std::clamp(value, 0.0, 1.0) * 255); };
  return CefColorSetARGB(255, channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent));
}

}  // namespace

@implementation RCEngine

+ (BOOL)startWithCachePath:(NSString *)cachePath keychain:(BOOL)keychain {
  if (gRunning) return YES;
  gMockKeychain = !keychain;
  if (![NSApp isKindOfClass:RCApplication.class]) {
    NSLog(@"Chromium needs RCApplication as the application class");
    return NO;
  }
  gLibrary = new CefScopedLibraryLoader();
  if (!gLibrary->LoadInMain()) {
    delete gLibrary;
    gLibrary = nullptr;
    return NO;
  }
  CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  settings.external_message_pump = true;
  // Otherwise it's "Chromium Safe Storage", which other Chromium browsers share.
  CefString(&settings.keychain_service_name) = "Rise Safe Storage";
  CefString(&settings.keychain_account_name) = "Rise";
  CefString(&settings.root_cache_path) = cachePath.UTF8String;
  CefString(&settings.cache_path) = [cachePath stringByAppendingPathComponent:@"Default"].UTF8String;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  gPump = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 1e10, 0, 0,
                                          ^(CFRunLoopTimerRef) { PumpWork(); });
  CFRunLoopAddTimer(CFRunLoopGetMain(), gPump, kCFRunLoopCommonModes);
  CefRefPtr<RiseApp> app(new RiseApp());
  if (!CefInitialize(args, settings, app.get(), nullptr)) {
    CFRunLoopTimerInvalidate(gPump);
    gPump = nullptr;
    return NO;
  }
  gRunning = true;
  SchedulePump(0);
  return YES;
}

+ (BOOL)isRunning {
  return gRunning;
}

+ (void)shutdown {
  if (!gRunning) return;
  gRunning = false;
  // Lets pages that are closing finish before Chromium stops.
  for (int i = 0; i < 10; i++) CefDoMessageLoopWork();
  CefShutdown();
  if (gPump) CFRunLoopTimerInvalidate(gPump);
  gPump = nullptr;
}

@end

@interface RCApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation RCApplication
- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
@end

// A second host of the page's frames, cropped to part of the page. It follows the page's frames
// as they come, upright whichever way the layers it's put in are flipped.
@interface RCLiveLayer : CALayer
- (instancetype)initWithPage:(RCBrowserView *)page rect:(NSRect)rect;
@end

@implementation RCLiveLayer {
  __weak RCBrowserView *_page;
  NSRect _rect;
  CALayer *_content, *_flip, *_host;
}
- (instancetype)initWithPage:(RCBrowserView *)page rect:(NSRect)rect {
  if (!(self = [super init])) return nil;
  _page = page;
  _rect = rect;
  self.anchorPoint = CGPointZero;
  self.bounds = CGRectMake(0, 0, rect.size.width, rect.size.height);
  self.masksToBounds = YES;
  _content = [CALayer layer];
  _flip = [CALayer layer];
  _host = [[NSClassFromString(@"CALayerHost") alloc] init];
  for (CALayer *layer in @[ _content, _flip, _host ]) {
    layer.anchorPoint = CGPointZero;
    layer.delegate = (id<CALayerDelegate>)self;
  }
  [_flip addSublayer:_host];
  [_content addSublayer:_flip];
  [self addSublayer:_content];
  [self setNeedsLayout];
  return self;
}
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
  return (id<CAAction>)NSNull.null;
}
- (void)layoutSublayers {
  [super layoutSublayers];
  RCBrowserView *page = _page;
  CALayer *original = page ? ContentHost(page.layer) : nil;
  if (!original) return;
  [_host setValue:[original valueForKey:@"contextId"] forKey:@"contextId"];
  // The page's top edge, then the crop's offset from it, in whichever direction y runs here.
  NSSize size = page.bounds.size;
  CGFloat top = page.isFlipped ? NSMinY(_rect) : size.height - NSMaxY(_rect);
  CGFloat y = self.contentsAreFlipped ? -top : NSHeight(_rect) + top - size.height;
  _content.frame = CGRectMake(-NSMinX(_rect), y, size.width, size.height);
  _flip.geometryFlipped = NO;
  _flip.frame = _content.bounds;
  // Flipped as many times over as Chromium's own layer is, so the page is the right way up.
  if (_flip.contentsAreFlipped != original.superlayer.contentsAreFlipped) _flip.geometryFlipped = YES;
}
@end

@implementation RCBrowserView {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<RiseClient> _client;
  CefRefPtr<CefRegistration> _devTools;
  int _nextMessageID;
  // Blocks taking a command's result and its error.
  NSMutableDictionary<NSNumber *, id> *_replies;
  // Commands asked for before Chromium had made the page.
  NSMutableArray<void (^)(void)> *_waiting;
  NSString *_mainFrameID;
  // Rise's scripts and message handlers, given to the page's process and every frame's.
  NSMutableArray<NSDictionary *> *_scripts;
  NSMutableDictionary<NSString *, NSDictionary *> *_handlers;
  // DevTools sessions of frames in processes of their own.
  NSMutableSet<NSString *> *_sessions;
  // Rise's scripts are in, so the page may load.
  BOOL _ready;
  NSData *_pendingState;
  NSMutableDictionary<NSNumber *, RCDownload *> *_downloads;
  // Chromium's tracking areas, set aside while the page is covered.
  NSMapTable<NSView *, NSArray<NSTrackingArea *> *> *_parkedAreas;
  NSURL *_pendingURL;
  // Asked to load while Chromium was still making the page: loads once it exists.
  BOOL _loadsWhenCreated;
  BOOL _closed;
}

- (instancetype)initWithFrame:(NSRect)frame URL:(NSURL *)url {
  self = [super initWithFrame:frame];
  if (self) {
    _pendingURL = url;
    _zoom = 1;
    _pageBackgroundColor = NSColor.whiteColor;
    _replies = [NSMutableDictionary dictionary];
    _waiting = [NSMutableArray array];
    _scripts = [NSMutableArray array];
    _handlers = [NSMutableDictionary dictionary];
    _sessions = [NSMutableSet set];
    _downloads = [NSMutableDictionary dictionary];
    _loadsWhenCreated = url != nil;
    self.wantsLayer = YES;
    if (gContextReady) [self createBrowser];
    else [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contextReady) name:RCContextReadyNotification object:nil];
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_browser) _browser->GetHost()->CloseBrowser(true);
}

- (void)contextReady {
  [NSNotificationCenter.defaultCenter removeObserver:self name:RCContextReadyNotification object:nil];
  [self createBrowser];
}

- (void)createBrowser {
  if (_closed || _client) return;
  _client = new RiseClient(self);
  CefWindowInfo window;
  NSSize size = self.bounds.size;
  window.SetAsChild((__bridge void *)self, CefRect(0, 0, (int)std::max(1.0, size.width), (int)std::max(1.0, size.height)));
  window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  settings.background_color = ARGB(_pageBackgroundColor);
  // Made empty: Rise's scripts go in first, then it loads or restores its history.
  CefBrowserHost::CreateBrowser(window, _client, "", settings, nullptr, nullptr);
}

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  _devTools = browser->GetHost()->AddDevToolsMessageObserver(new DevToolsReplies(self));
  NSArray *waiting = _waiting.copy;
  [_waiting removeAllObjects];
  for (void (^command)(void) in waiting) command();
  if (_zoom != 1) [self applyZoom];
  [self fitBrowserView];
  // The page has no renderer until it first loads, so nothing in it answers yet; DevTools holds
  // the setup and hands it over, in order, when the first load makes one, before its document.
  [self prepareSession:@"" done:nil];
  [self becomeReady];
}

- (void)becomeReady {
  if (!_browser || _ready) return;
  _ready = YES;
  if (_pendingState) {
    NSData *state = _pendingState;
    _pendingState = nil;
    if ([self restore:state]) {
      _loadsWhenCreated = NO;
      return;
    }
  }
  if (_loadsWhenCreated && _pendingURL) _browser->GetMainFrame()->LoadURL(std::string(_pendingURL.absoluteString.UTF8String));
  _loadsWhenCreated = NO;
}

- (void)browserClosed {
  _browser = nullptr;
  _ready = NO;
  [_sessions removeAllObjects];
  _devTools = nullptr;
  NSDictionary *replies = _replies.copy;
  [_replies removeAllObjects];
  for (void (^reply)(NSDictionary *, NSDictionary *) in replies.allValues) reply(nil, @{@"message": @"closed"});
}

// Chromium's own view fills this one at every size, so a resize lays the page out again. Only
// the last size in a turn of the run loop reaches it, in the layout pass just before the frame is
// drawn: Chromium draws every size it's given, a few frames later, so a size set and replaced at
// once (a Peek placed, then started off from elsewhere) would otherwise show as a blank band.
- (void)fitBrowserView {
  for (NSView *child in self.subviews) child.frame = self.bounds;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self fitContentLayersIn:self.layer];
  [CATransaction commit];
}
// Chromium shows its frames in a flipped layer that follows its parent only by Core Animation's
// autoresizing, which drifts over the many resizes of a Peek or split motion, leaving the page
// offset from its view with a blank band. It's held to its parent's bounds instead.
- (void)fitContentLayersIn:(CALayer *)layer {
  for (CALayer *sublayer in layer.sublayers) {
    if (sublayer.geometryFlipped && CGPointEqualToPoint(sublayer.anchorPoint, CGPointZero)) {
      if (!CGRectEqualToRect(sublayer.frame, layer.bounds)) sublayer.frame = layer.bounds;
    } else {
      [self fitContentLayersIn:sublayer];
    }
  }
}
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  self.needsLayout = YES;
}
- (void)layout {
  [super layout];
  [self fitBrowserView];
}

- (void)updateURL:(NSURL *)url {
  _URL = url;
  [self.delegate browserViewDidChange:self];
}
- (void)updateTitle:(NSString *)title {
  _title = title;
  [self.delegate browserViewDidChange:self];
}
- (void)updateProgress:(double)progress {
  _progress = progress;
  [self.delegate browserViewDidChange:self];
}
- (void)setCovered:(BOOL)covered {
  if (covered == _covered) return;
  _covered = covered;
  if (covered) {
    _parkedAreas = [NSMapTable strongToStrongObjectsMapTable];
    [self parkTrackingAreasIn:self];
    [self updateHoveredURL:nil];
  } else {
    for (NSView *view in _parkedAreas) for (NSTrackingArea *area in [_parkedAreas objectForKey:view]) [view addTrackingArea:area];
    _parkedAreas = nil;
  }
  [self.window invalidateCursorRectsForView:self];
}
- (void)parkTrackingAreasIn:(NSView *)view {
  for (NSView *child in view.subviews) {
    NSArray *areas = child.trackingAreas;
    if (areas.count) {
      [_parkedAreas setObject:areas forKey:child];
      for (NSTrackingArea *area in areas) [child removeTrackingArea:area];
    }
    [self parkTrackingAreasIn:child];
  }
}

- (void)updateHoveredURL:(NSURL *)url {
  if (_covered && url) return;
  if (url == _hoveredURL || [url isEqual:_hoveredURL]) return;
  _hoveredURL = url;
  if ([self.delegate respondsToSelector:@selector(browserView:didHoverLink:)]) [self.delegate browserView:self didHoverLink:url];
}
- (BOOL)openURL:(NSURL *)url disposition:(RCOpenDisposition)disposition userGesture:(BOOL)gesture {
  return [self.delegate respondsToSelector:@selector(browserView:openURL:disposition:userGesture:)] &&
         [self.delegate browserView:self openURL:url disposition:disposition userGesture:gesture];
}
- (BOOL)canOpenInPeek {
  return [self.delegate respondsToSelector:@selector(browserView:openLinkInPeek:)];
}
- (void)openLinkInPeek:(NSURL *)url {
  [self.delegate browserView:self openLinkInPeek:url];
}

// MARK: DevTools

- (void)devTools:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *_Nullable result))completion {
  [self devTools:method params:params session:@"" completion:completion];
}
/// Sends a DevTools command to the page, or to the frame process of `session`; completes with
/// its result, or nil if it failed.
- (void)devTools:(NSString *)method params:(NSDictionary *)params session:(NSString *)session
      completion:(void (^)(NSDictionary *_Nullable result))completion {
  [self devTools:method params:params session:session reply:^(NSDictionary *result, NSDictionary *) { completion(result); }];
}
- (void)devTools:(NSString *)method params:(NSDictionary *)params session:(NSString *)session
           reply:(void (^)(NSDictionary *_Nullable result, NSDictionary *_Nullable error))reply {
  if (_closed) {
    reply(nil, @{@"message": @"closed"});
    return;
  }
  if (!_browser) {
    __weak RCBrowserView *weakSelf = self;
    [_waiting addObject:^{ [weakSelf devTools:method params:params session:session reply:reply]; }];
    return;
  }
  int messageID = ++_nextMessageID;
  NSMutableDictionary *message = [@{@"id": @(messageID), @"method": method, @"params": params ?: @{}} mutableCopy];
  if (session.length) message[@"sessionId"] = session;
  NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
  if (!json) {
    reply(nil, @{@"message": @"unserializable"});
    return;
  }
  _replies[@(messageID)] = (id)^(NSDictionary *result, NSDictionary *error) { reply(result, error); };
  if (!_browser->GetHost()->SendDevToolsMessage(json.bytes, json.length)) {
    [_replies removeObjectForKey:@(messageID)];
    reply(nil, @{@"message": @"not sent"});
  }
}
- (void)devToolsMessage:(NSData *)json {
  // With Runtime on, the page's console and contexts report too; those are let go unread.
  static const char *const ignored[] = {"\"Runtime.consoleAPICalled\"", "\"Runtime.exceptionThrown\"",
                                        "\"Runtime.executionContextDestroyed\"", "\"Runtime.executionContextsCleared\""};
  const char *bytes = (const char *)json.bytes;
  size_t head = std::min<size_t>(json.length, 96);
  for (const char *method : ignored)
    if (memmem(bytes, head, method, strlen(method)) && !memmem(bytes, head, "\"id\"", 4)) return;
  NSDictionary *message = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  if (![message isKindOfClass:NSDictionary.class]) return;
  if (NSNumber *messageID = message[@"id"]) {
    void (^reply)(NSDictionary *, NSDictionary *) = (id)_replies[messageID];
    if (!reply) return;
    [_replies removeObjectForKey:messageID];
    reply(message[@"result"], message[@"error"]);
    return;
  }
  NSString *method = message[@"method"], *session = message[@"sessionId"] ?: @"";
  NSDictionary *params = message[@"params"];
  if ([method isEqualToString:@"Target.attachedToTarget"]) {
    NSString *child = params[@"sessionId"];
    if (!child) return;
    __weak RCBrowserView *weakSelf = self;
    // Chromium reports the frame from inside attaching it, before it holds the frame; a resume
    // sent now would release nothing and use up the only one, so it goes on the next turn.
    void (^resume)(void) = ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf devTools:@"Runtime.runIfWaitingForDebugger" params:@{} session:child completion:^(NSDictionary *) {}];
      });
    };
    if (![params[@"targetInfo"][@"type"] isEqualToString:@"iframe"]) { resume(); return; }
    [_sessions addObject:child];
    // The frame waits for Rise's scripts, then starts: commands run in order, and a paused frame
    // can't answer any of them before it's let go.
    [self prepareSession:child done:nil];
    resume();
  } else if ([method isEqualToString:@"Runtime.executionContextCreated"] && session.length) {
    [self frameDocumentStarted:params[@"context"] session:session];
  } else if ([method isEqualToString:@"Target.detachedFromTarget"]) {
    if (NSString *child = params[@"sessionId"]) {
      [_sessions removeObject:child];
    }
  } else if ([method isEqualToString:@"Runtime.bindingCalled"]) {
    [self bindingCalled:params session:session];
  }
}

// MARK: Rise's scripts

static NSString *BindingSecret() {
  static NSString *secret = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
  return secret;
}
static NSString *BindingName(NSString *handler) {
  return [NSString stringWithFormat:@"__rise%@_%@", BindingSecret(), handler];
}
static NSString *JSONText(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ?: NSNull.null ] options:0 error:nil];
  NSString *list = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[null]";
  return [list substringWithRange:NSMakeRange(1, list.length - 2)];
}

/// Gives a session, the page's or a frame's, Rise's handlers and scripts, in that order.
- (void)prepareSession:(NSString *)session done:(nullable void (^)(void))done {
  // A context made later gets Rise's bindings as it's made only while Runtime is on; Rise's own
  // worlds are made by its scripts, after the handlers are added.
  [self devTools:@"Runtime.enable" params:@{} session:session completion:^(NSDictionary *) {}];
  [self devTools:@"Target.setAutoAttach"
          params:@{@"autoAttach": @YES, @"waitForDebuggerOnStart": @YES, @"flatten": @YES, @"filter": @[ @{@"type": @"iframe"} ]}
         session:session completion:^(NSDictionary *) {}];
  for (NSString *name in _handlers) [self sendHandler:name to:session];
  for (NSDictionary *script in _scripts) [self sendScript:script to:session];
  // Commands run in order, so this answers once the others are in.
  if (done) [self devTools:@"Runtime.evaluate" params:@{@"expression": @"0"} session:session completion:^(NSDictionary *) { done(); }];
}
/// A frame of another site starts a document. Its scripts-on-new-document can miss the frame's
/// first document, which starts before Rise's session reaches its new process, so Rise's scripts
/// are run in it here too; each runs once a document.
- (void)frameDocumentStarted:(NSDictionary *)context session:(NSString *)session {
  NSNumber *contextID = context[@"id"];
  NSString *frameID = context[@"auxData"][@"frameId"];
  if (![context[@"auxData"][@"isDefault"] boolValue] || !contextID || !frameID) return;
  for (NSDictionary *script in _scripts) {
    if (![script[@"wrapped"] boolValue]) continue;
    NSString *source = script[@"source"], *world = script[@"world"];
    if (!world) {
      [self devTools:@"Runtime.evaluate" params:@{@"expression": source, @"contextId": contextID} session:session completion:^(NSDictionary *) {}];
      continue;
    }
    __weak RCBrowserView *weakSelf = self;
    [self devTools:@"Page.createIsolatedWorld" params:@{@"frameId": frameID, @"worldName": world} session:session
        completion:^(NSDictionary *result) {
          if (NSNumber *isolated = result[@"executionContextId"])
            [weakSelf devTools:@"Runtime.evaluate" params:@{@"expression": source, @"contextId": isolated} session:session
                    completion:^(NSDictionary *) {}];
        }];
  }
}
- (void)sendHandler:(NSString *)name to:(NSString *)session {
  NSMutableDictionary *params = [@{@"name": BindingName(name)} mutableCopy];
  if (NSString *world = _handlers[name][@"world"]) params[@"executionContextName"] = world;
  [self devTools:@"Runtime.addBinding" params:params session:session completion:^(NSDictionary *) {}];
}
- (void)sendScript:(NSDictionary *)script to:(NSString *)session {
  NSMutableDictionary *params = [@{@"source": script[@"source"], @"runImmediately": @YES} mutableCopy];
  if (NSString *world = script[@"world"]) params[@"worldName"] = world;
  [self devTools:@"Page.addScriptToEvaluateOnNewDocument" params:params session:session completion:^(NSDictionary *) {}];
}
- (NSArray<NSString *> *)allSessions {
  return [@[ @"" ] arrayByAddingObjectsFromArray:_sessions.allObjects];
}

- (void)addMessageHandler:(NSString *)name world:(NSString *)world replies:(BOOL)replies {
  NSMutableDictionary *handler = [@{@"replies": @(replies)} mutableCopy];
  if (world) handler[@"world"] = world;
  _handlers[name] = handler;
  if (_browser) for (NSString *session in self.allSessions) [self sendHandler:name to:session];
}

- (void)addUserScript:(NSString *)source world:(NSString *)world mainFrameOnly:(BOOL)mainFrameOnly
             handlers:(NSArray<NSString *> *)handlers {
  NSMutableArray *bindings = [NSMutableArray array];
  for (NSString *name in handlers) [bindings addObject:@[ name, BindingName(name), _handlers[name][@"replies"] ?: @NO ]];
  // Each handler's binding is taken as the document starts and removed from the page, so only
  // Rise's script can post with it, whatever frame it's in; the frame reports where it is.
  NSString *ran = [NSString stringWithFormat:@"__rise%@_ran%lu", BindingSecret(), (unsigned long)_scripts.count];
  NSString *wrapped = [NSString stringWithFormat:@"(() => {\n"
    "if (globalThis[%@]) return;\n"
    "Object.defineProperty(globalThis, %@, {value: true});\n"
    "const riseHandlers = (() => {\n"
    "  const handlers = {}, isTop = window === window.top, stringify = JSON.stringify;\n"
    "  for (const [name, binding, replies] of %@) {\n"
    "    let send = globalThis[binding];\n"
    "    if (typeof send === 'function') { try { delete globalThis[binding]; } catch {} } else send = null;\n"
    "    const post = message => {\n"
    "      if (!send && typeof globalThis[binding] === 'function') { send = globalThis[binding]; try { delete globalThis[binding]; } catch {} }\n"
    "      send?.(stringify({...message, origin: location.origin, main: isTop}));\n"
    "    };\n"
    "    if (!replies) { handlers[name] = { postMessage: body => post({body}) }; continue; }\n"
    "    const waiting = new Map(); let next = 0;\n"
    "    Object.defineProperty(globalThis, binding + '_reply', { configurable: true, value: (id, ok, value) => {\n"
    "      const settle = waiting.get(id); if (settle) { waiting.delete(id); settle(ok, value); } } });\n"
    "    handlers[name] = { postMessage: body => new Promise((resolve, reject) => {\n"
    "      const id = ++next; waiting.set(id, (ok, value) => ok ? resolve(value) : reject(new Error(value)));\n"
    "      post({id, body});\n"
    "    }) };\n"
    "  }\n"
    "  return handlers;\n"
    "})();\n"
    "if (%@ && !(window === window.top)) return;\n"
    "%@\n"
    "})();", JSONText(ran), JSONText(ran), JSONText(bindings), mainFrameOnly ? @"true" : @"false", source];
  NSMutableDictionary *script = [@{@"source": wrapped, @"wrapped": @YES} mutableCopy];
  if (world) script[@"world"] = world;
  [_scripts addObject:script];
  if (_browser) for (NSString *session in self.allSessions) [self sendScript:script to:session];
}

- (void)bindingCalled:(NSDictionary *)params session:(NSString *)session {
  NSString *binding = params[@"name"], *prefix = BindingName(@"");
  if (![binding hasPrefix:prefix]) return;
  NSString *name = [binding substringFromIndex:prefix.length];
  NSDictionary *handler = _handlers[name];
  NSData *data = [params[@"payload"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSNumber *context = params[@"executionContextId"];
  if (!handler || ![payload isKindOfClass:NSDictionary.class] || !context) return;
  // Only the page's own process holds its main frame.
  BOOL main = [payload[@"main"] boolValue] && session.length == 0;
  RCFrame *frame = [[RCFrame alloc] initWithSession:session context:context.integerValue main:main
                                             origin:[payload[@"origin"] isKindOfClass:NSString.class] ? payload[@"origin"] : @"null"];
  id body = payload[@"body"] ?: NSNull.null;
  void (^reply)(id, NSString *) = nil;
  if ([handler[@"replies"] boolValue]) {
    NSNumber *replyID = payload[@"id"];
    __weak RCBrowserView *weakSelf = self;
    __block BOOL replied = NO;
    reply = ^(id value, NSString *error) {
      if (replied || !replyID) return;
      replied = YES;
      NSString *expression = [NSString stringWithFormat:@"globalThis[%@]?.(%@, %@, %@)", JSONText([binding stringByAppendingString:@"_reply"]),
                                                        replyID, error ? @"false" : @"true", JSONText(error ?: value)];
      [weakSelf devTools:@"Runtime.evaluate" params:@{@"expression": expression, @"contextId": context} session:session
              completion:^(NSDictionary *) {}];
    };
  }
  if ([self.delegate respondsToSelector:@selector(browserView:didReceiveMessage:handler:frame:reply:)]) {
    [self.delegate browserView:self didReceiveMessage:body handler:name frame:frame reply:reply];
  } else if (reply) {
    reply(nil, @"No handler");
  }
}

- (void)evaluateFunctionBody:(NSString *)functionBody arguments:(NSDictionary<NSString *, id> *)arguments
                       frame:(RCFrame *)frame world:(NSString *)world
                  completion:(void (^)(id _Nullable, NSString *_Nullable))completion {
  NSString *expression = [self expressionFor:functionBody arguments:arguments];
  if (!expression) { completion(nil, @"Arguments can't be passed to the page"); return; }
  void (^run)(NSNumber *, NSString *) = ^(NSNumber *context, NSString *session) {
    NSMutableDictionary *params = [@{@"expression": expression, @"awaitPromise": @YES, @"returnByValue": @YES} mutableCopy];
    if (context) params[@"contextId"] = context;
    [self devTools:@"Runtime.evaluate" params:params session:session reply:^(NSDictionary *result, NSDictionary *error) {
      if (!result) { completion(nil, error[@"message"] ?: @"The page went away"); return; }
      if (NSDictionary *exception = result[@"exceptionDetails"]) {
        completion(nil, exception[@"exception"][@"description"] ?: exception[@"text"] ?: @"The script threw");
        return;
      }
      id value = result[@"result"][@"value"];
      completion(value == NSNull.null ? nil : value, nil);
    }];
  };
  if (frame) { run(@(frame.context), frame.session); return; }
  if (!world) { run(nil, @""); return; }
  [self world:world completion:^(NSNumber *context) {
    if (context) run(context, @"");
    else completion(nil, @"No such world");
  }];
}
- (nullable NSString *)expressionFor:(NSString *)functionBody arguments:(NSDictionary<NSString *, id> *)arguments {
  NSData *values = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
  if (!values) return nil;
  NSString *names = [arguments.allKeys componentsJoinedByString:@", "];
  return [NSString stringWithFormat:@"(async ({%@}) => {\n%@\n})(%@)", names, functionBody,
                                    [[NSString alloc] initWithData:values encoding:NSUTF8StringEncoding]];
}

/// The isolated world `world` in the page's current document, made if need be.
- (void)world:(NSString *)world completion:(void (^)(NSNumber *_Nullable context))completion {
  __weak RCBrowserView *weakSelf = self;
  void (^create)(NSString *, BOOL) = ^(NSString *frameID, BOOL retry) {
    [weakSelf devTools:@"Page.createIsolatedWorld" params:@{@"frameId": frameID, @"worldName": world}
            completion:^(NSDictionary *result) {
              NSNumber *context = result[@"executionContextId"];
              if (context || !retry) { completion(context); return; }
              // The page's frame changed; look it up again once.
              RCBrowserView *view = weakSelf;
              if (!view) { completion(nil); return; }
              view->_mainFrameID = nil;
              [view world:world completion:completion];
            }];
  };
  if (_mainFrameID) { create(_mainFrameID, YES); return; }
  [self devTools:@"Page.getFrameTree" params:@{} completion:^(NSDictionary *result) {
    NSString *frameID = result[@"frameTree"][@"frame"][@"id"];
    RCBrowserView *view = weakSelf;
    if (!frameID || !view) { completion(nil); return; }
    view->_mainFrameID = frameID;
    create(frameID, NO);
  }];
}

- (void)evaluateFunctionBody:(NSString *)functionBody arguments:(NSDictionary<NSString *, id> *)arguments
                       world:(NSString *)world completion:(void (^)(id _Nullable))completion {
  [self evaluateFunctionBody:functionBody arguments:arguments frame:nil world:world
                  completion:^(id result, NSString *) { completion(result); }];
}

- (void)addScriptToEveryDocument:(NSString *)source world:(NSString *)world {
  NSDictionary *script = @{@"source": source, @"world": world};
  [_scripts addObject:script];
  if (_browser) for (NSString *session in self.allSessions) [self sendScript:script to:session];
}

// MARK: History, sound, downloads and permissions

- (NSData *)navigationState {
  CefRefPtr<CefBinaryValue> state = _browser ? _browser->GetHost()->GetNavigationState() : nullptr;
  if (!state || !state->GetSize()) return nil;
  NSMutableData *data = [NSMutableData dataWithLength:state->GetSize()];
  state->GetData(data.mutableBytes, data.length, 0);
  return data;
}
- (BOOL)restore:(NSData *)state {
  if (!_browser || !state.length) return NO;
  return _browser->GetHost()->RestoreNavigationState(CefBinaryValue::Create(state.bytes, state.length));
}
- (void)restoreNavigationState:(NSData *)state fallback:(NSURL *)fallback {
  _pendingURL = fallback;
  _loadsWhenCreated = YES;
  if (!_ready) {
    _pendingState = state;
    return;
  }
  if (![self restore:state]) _browser->GetMainFrame()->LoadURL(std::string(fallback.absoluteString.UTF8String));
}

- (void)updateAudible:(BOOL)audible {
  if (audible == _audible) return;
  _audible = audible;
  [self.delegate browserViewDidChange:self];
}

- (NSString *)destinationForDownload:(CefRefPtr<CefDownloadItem>)item suggestedName:(NSString *)name {
  if (![self.delegate respondsToSelector:@selector(browserView:destinationForDownload:suggestedName:)]) return nil;
  RCDownload *download = [[RCDownload alloc] init];
  [download updateFrom:item callback:nullptr];
  NSURL *destination = [self.delegate browserView:self destinationForDownload:download suggestedName:name];
  if (!destination) return nil;
  _downloads[@(item->GetId())] = download;
  return destination.path;
}
- (void)updateDownload:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  RCDownload *download = _downloads[@(item->GetId())];
  if (!download) return;
  [download updateFrom:item callback:callback];
  if (download.state == RCDownloadStateFinished || download.state == RCDownloadStateCancelled ||
      download.state == RCDownloadStateFailed) {
    [_downloads removeObjectForKey:@(item->GetId())];
  }
}

- (void)requestPermissions:(RCPermission)permissions origin:(NSString *)origin decide:(void (^)(RCPermission))decide {
  if (![self.delegate respondsToSelector:@selector(browserView:requestPermissions:origin:decide:)]) {
    decide(0);
    return;
  }
  __block BOOL decided = NO;
  [self.delegate browserView:self requestPermissions:permissions origin:origin decide:^(RCPermission allowed) {
    if (decided) return;
    decided = YES;
    decide(allowed);
  }];
}
- (void)withdrawPermissionRequest {
  if ([self.delegate respondsToSelector:@selector(browserViewDidWithdrawPermissionRequest:)]) {
    [self.delegate browserViewDidWithdrawPermissionRequest:self];
  }
}

- (CALayer *)liveLayerShowing:(NSRect)rect {
  if (!ContentHost(self.layer) || NSIsEmptyRect(rect)) return nil;
  return [[RCLiveLayer alloc] initWithPage:self rect:rect];
}

- (void)snapshotWithCompletion:(void (^)(NSImage *_Nullable))completion {
  NSSize size = self.bounds.size;
  [self devTools:@"Page.captureScreenshot"
          params:@{@"format": @"jpeg", @"quality": @92, @"fromSurface": @YES, @"optimizeForSpeed": @YES}
      completion:^(NSDictionary *result) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:result[@"data"] ?: @"" options:0];
        NSImage *image = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (image && size.width > 0 && size.height > 0) image.size = size;
        completion(image);
      }];
}

- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward {
  _isLoading = loading;
  _canGoBack = back;
  _canGoForward = forward;
  [self.delegate browserViewDidChange:self];
}

- (void)loadURL:(NSURL *)url {
  if (!_ready) {
    _pendingURL = url;
    _pendingState = nil;
    _loadsWhenCreated = YES;
    return;
  }
  _browser->GetMainFrame()->LoadURL(std::string(url.absoluteString.UTF8String));
}
- (void)goBack {
  if (_browser) _browser->GoBack();
}
- (void)goForward {
  if (_browser) _browser->GoForward();
}
- (void)reload {
  if (_browser) _browser->Reload();
}
- (void)reloadIgnoringCache {
  if (_browser) _browser->ReloadIgnoreCache();
}
- (void)stopLoading {
  if (_browser) _browser->StopLoad();
}
- (void)setAudioMuted:(BOOL)muted {
  if (_browser) _browser->GetHost()->SetAudioMuted(muted);
}

// Chromium zooms in steps of 20%: level n is 1.2^n.
- (void)setZoom:(double)zoom {
  _zoom = zoom;
  [self applyZoom];
}
- (void)applyZoom {
  if (_browser) _browser->GetHost()->SetZoomLevel(std::log(std::max(0.01, _zoom)) / std::log(1.2));
}

- (void)close {
  _closed = YES;
  if (_browser) _browser->GetHost()->CloseBrowser(true);
}

@end
