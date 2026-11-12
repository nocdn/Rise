import AppKit

/// An event on the card's timeline, or an all-day event above it, in a light wash of its own
/// colour inside a deeper border. As in Calendar, an invitation not yet answered is only
/// outlined, a declined one is also struck through, and one answered Maybe is striped.
final class CalendarEventChip: NSButton {
    let event: CalendarEvent
    private let name = NSTextField(labelWithString: "")
    var onOpen: (() -> Void)?
    /// A right click's menu.
    var onMenu: (() -> NSMenu?)?
    private var outlined: Bool { event.answer == .no || event.invited == true && event.answer == nil }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isPast = false { didSet { if isPast != oldValue { alphaValue = isPast ? 0.55 : 1 } } }
    private var theme = RiseTheme.neutral, panel = NSColor.white
    override var isFlipped: Bool { true }
    init(_ event: CalendarEvent, time: String?) {
        self.event = event
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(open); wantsLayer = true
        name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
        addSubview(name)
        // Its exact times and the start of its description; the title is on the chip.
        toolTip = ([time ?? "All day"]+(event.description.map { [$0] } ?? [])).joined(separator: "\n")
        setAccessibilityLabel(event.title); setAccessibilityValue(time ?? "All day")
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The event's colour, or the theme's accent for one without: blended into the card's
    /// surface, the fill lighter than the border.
    static func colors(_ theme: RiseTheme, panel: NSColor, color: UInt32?, hovered: Bool = false) -> (fill: NSColor, border: NSColor, text: NSColor) {
        let dark = theme == .dark, base: CGFloat = dark ? 0.32 : 0.2, tint = color.map(NSColor.init(hex:)) ?? theme.accent
        let fill = panel.blended(withFraction: base+(hovered ? 0.08 : 0), of: tint) ?? tint
        let border = panel.blended(withFraction: dark ? 0.48 : 0.38, of: tint) ?? tint
        return (fill, border, dark ? NSColor.white.withAlphaComponent(0.92) : theme.text)
    }
    func applyTheme(_ theme: RiseTheme, panel: NSColor) {
        self.theme = theme; self.panel = panel
        let text = Self.colors(theme, panel: panel, color: event.color).text
        name.attributedStringValue = NSAttributedString(string: event.title, attributes: [
            .foregroundColor: event.answer == .no ? text.withAlphaComponent(0.6) : text,
            .strikethroughStyle: event.answer == .no ? NSUnderlineStyle.single.rawValue : 0,
        ].merging(name.font.map { [.font: $0] } ?? [:]) { a, _ in a })
        needsDisplay = true
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?()?.separatingIconSections() }
    /// A quick side-to-side shake, for an answer Calendar didn't take.
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -4, 4, -2, 2, 0]; shake.duration = 0.32
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "shake")
    }
    override func layout() {
        super.layout()
        let compact = bounds.height < 22
        let font = NSFont.systemFont(ofSize: compact ? 11 : 12.5, weight: .medium)
        if name.font != font { name.font = font; applyTheme(theme, panel: panel) }
        let line = ceil(NSLayoutManager().defaultLineHeight(for: name.font!))
        let y = compact ? max(0, (bounds.height-line)/2) : 4
        name.frame = NSRect(x: 6, y: y, width: max(0, bounds.width-10), height: min(line, bounds.height))
        name.isHidden = bounds.height < 9
    }
    override func draw(_ dirtyRect: NSRect) {
        let colors = Self.colors(theme, panel: panel, color: event.color, hovered: isHovered)
        // Continuous corners, like the card around it.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = PageOutline.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: 4.5, continuous: true)
        let fill = outlined ? (panel.blended(withFraction: isHovered ? 0.08 : 0, of: colors.border) ?? panel) : colors.fill
        context.addPath(path); context.setFillColor(fill.cgColor); context.fillPath()
        if event.answer == .maybe {
            context.saveGState(); context.addPath(path); context.clip()
            context.setStrokeColor(colors.border.withAlphaComponent(0.55).cgColor); context.setLineWidth(2)
            var x = -bounds.height
            while x < bounds.width { context.move(to: CGPoint(x: x, y: bounds.height)); context.addLine(to: CGPoint(x: x+bounds.height, y: 0)); x += 8 }
            context.strokePath(); context.restoreGState()
        }
        context.addPath(path); context.setStrokeColor(colors.border.cgColor); context.setLineWidth(1); context.strokePath()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc private func open() { onOpen?() }
}

/// The selected day, hour by hour from midnight: lines, hour labels and the time now.
final class CalendarTimeline: FlippedView {
    static let hourHeight: CGFloat = 42, labelWidth: CGFloat = 54, trailing: CGFloat = 6
    /// The hour lines, drawn below their hour's point, and an event's room from them.
    static let lineWidth: CGFloat = 0.5, chipGap: CGFloat = 2
    var midnight = Calendar.current.startOfDay(for: Date())
    var theme = RiseTheme.neutral { didSet { needsDisplay = true } }
    private let now = FlippedView(), dot = FlippedView()
    private static let hourFormat: DateFormatter = {
        let formatter = DateFormatter()
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        formatter.setLocalizedDateFormatFromTemplate(twelveHour ? "j" : "HH:mm")
        return formatter
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        now.wantsLayer = true; dot.wantsLayer = true; dot.layer?.cornerRadius = 4
        addSubview(now); addSubview(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The day, then the same room below it as beside the events.
    static var dayHeight: CGFloat { 24*hourHeight }
    static var contentHeight: CGFloat { dayHeight+trailing }
    func y(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(midnight)/3600)*Self.hourHeight }
    /// Above the events, as in Calendar.
    func raiseNow() { [now, dot].forEach { $0.removeFromSuperview(); addSubview($0) } }
    func layoutNow() {
        now.isHidden = !Calendar.current.isDateInToday(midnight); dot.isHidden = now.isHidden
        let color = theme == .dark ? NSColor.white : theme.selectedText
        now.layer?.backgroundColor = color.cgColor; dot.layer?.backgroundColor = color.cgColor
        let y = y(Date()).rounded()
        now.frame = NSRect(x: Self.labelWidth-4, y: y-0.75, width: bounds.width-Self.labelWidth+4-Self.trailing, height: 1.5)
        dot.frame = NSRect(x: Self.labelWidth-8, y: y-4, width: 8, height: 8)
    }
    override func draw(_ dirtyRect: NSRect) {
        let line = theme.text.withAlphaComponent(theme == .dark ? 0.14 : 0.1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.muted]
        for hour in 0..<24 {
            let y = CGFloat(hour)*Self.hourHeight
            guard y+Self.hourHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            line.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: Self.lineWidth).fill()
            guard let date = Calendar.current.date(byAdding: .hour, value: hour, to: midnight) else { continue }
            (Self.hourFormat.string(from: date).uppercased() as NSString).draw(at: NSPoint(x: 8, y: y+6), withAttributes: attributes)
        }
    }
}

/// The same surface and positioning springs as the Gmail card, over today's timeline, which
/// opens at the hour now.
@MainActor final class CalendarTooltip: FlippedView, NSMenuDelegate {
    static let width: CGFloat = 264, preferredHeight: CGFloat = 268
    static let allDayHeight: CGFloat = 22, allDayGap: CGFloat = 4
    static let navigationHeight: CGFloat = 28
    let scroll = CardScrollView()
    let timeline = CalendarTimeline(frame: .zero)
    private let panel = Surface(radius: FindBar.radius)
    private let clip = FlippedView(), allDay = FlippedView(), divider = Surface()
    private let dayClip = FlippedView(), dayBody = Surface()
    private let navigation = Surface()
    let dayLabel = NSTextField(labelWithString: "")
    let todayButton = ChromeButton(symbol: "arrow.uturn.backward", size: 14, title: "Go to today", action: {})
    private var navigationSlide = MotionSpring(0)
    private var daySlide = MotionSpring(0), dayDirection: CGFloat = 1
    private var outgoingDay: CalendarDayImage?, slidesDays = false
    private var daySwipe = CalendarDaySwipe()
    private var ownsScroll = false, lastScroll: TimeInterval?
    private var lastDayScroll: NSEvent?, lastDayScrollConsumed = false
    private weak var agenda: CalendarAgenda?
    private(set) var chips: [CalendarEventChip] = []
    private(set) var allDayChips: [CalendarEventChip] = []
    private let moreAllDay = NSTextField(labelWithString: "")
    let message = NSTextField(labelWithString: "")
    let shimmer = InputShimmer()
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private var height = MotionSpring(0), top = MotionSpring(0)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?, clock: Timer?
    private var anchorTop: CGFloat = 0, maxBottom: CGFloat = 0
    private var theme = RiseTheme.neutral
    private var events: [CalendarEvent] = []
    private(set) var key: String?
    var onPointer: ((Bool) -> Void)?
    var onRetry: (() -> Void)?
    var onOpen: ((CalendarEvent) -> Void)?
    /// An event's right-click menu.
    var menuFor: ((CalendarEvent) -> NSMenu?)?
    /// While an event's menu is open, the card stays, with the event highlighted.
    private var menuEvent: String?
    private var background: NSColor { theme == .dark ? theme.popup : TabAppearance.selectedFill(theme) }

    init() {
        super.init(frame: .zero)
        isHidden = true; wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        panel.clipsToBounds = false
        clip.wantsLayer = true; clip.layer?.cornerRadius = FindBar.radius
        clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true
        dayClip.wantsLayer = true; dayClip.layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.verticalScroller = GmailScroller(); scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.documentView = timeline; scroll.contentView.postsBoundsChangedNotifications = true
        scroll.interceptScroll = { [weak self] in self?.handleDayScroll($0) ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        message.font = .systemFont(ofSize: 12); message.alignment = .center
        message.maximumNumberOfLines = 2; message.lineBreakMode = .byWordWrapping
        shimmer.configureForSmartRename(field: message)
        retry.isBordered = false; retry.font = .systemFont(ofSize: 12, weight: .medium)
        retry.target = self; retry.action = #selector(retryLoading)
        moreAllDay.font = .systemFont(ofSize: 11, weight: .medium)
        dayLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dayLabel.lineBreakMode = .byTruncatingTail
        todayButton.title = "Today"; todayButton.imagePosition = .imageLeading; todayButton.imageHugsTitle = true
        todayButton.image = TablerIcon.image("M9.333 13.667L6 10.333L9.333 7M6 10.333h9.167a3.333 3.333 0 0 1 0 6.667h-.834", size: 18)
        todayButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        todayButton.actionBlock = { [weak self] in self?.goToToday() }
        navigation.addSubview(dayLabel); navigation.addSubview(todayButton)
        dayBody.addSubview(scroll); dayBody.addSubview(allDay); dayBody.addSubview(divider)
        dayBody.addSubview(message); dayBody.addSubview(retry)
        dayClip.addSubview(dayBody); clip.addSubview(dayClip)
        clip.addSubview(navigation)
        allDay.addSubview(moreAllDay)
        panel.addSubview(clip); addSubview(panel)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        top.configure(response: FindMotion.swapResponse, bounce: 0)
        ChromeSlideMotion.configure(&daySlide, showing: true)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || key == nil ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true); updateHover() }
    override func mouseExited(with event: NSEvent) { if menuEvent == nil { onPointer?(false) }; updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func scrollWheel(with event: NSEvent) {
        if !handleDayScroll(event) { super.scrollWheel(with: event) }
    }
    private func handleDayScroll(_ event: NSEvent) -> Bool {
        guard key != nil else { return false }
        if event === lastDayScroll { return lastDayScrollConsumed }
        let result = daySwipe.handle(event)
        lastDayScroll = event; lastDayScrollConsumed = result.consumed
        if let day = result.day { browseDay(by: day) }
        return result.consumed
    }
    /// Claim the gesture before the window's page-history router sees it,
    /// including the undecided first deltas and momentum after the pointer leaves.
    /// nil leaves page history in charge; false skips history but leaves native
    /// vertical dispatch alone; true takes the event entirely.
    func routeScroll(_ event: NSEvent) -> Bool? {
        guard event.type == .scrollWheel, key != nil, !isHidden, window != nil else { return nil }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) ||
            event.phase.isEmpty && event.momentumPhase.isEmpty && lastScroll.map({ event.timestamp-$0 > 0.3 }) == true {
            ownsScroll = false
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside, !ownsScroll { daySwipe = CalendarDaySwipe(); lastDayScroll = nil; ownsScroll = true }
        guard ownsScroll else { return nil }
        lastScroll = event.timestamp
        let consumed = handleDayScroll(event)
        if !inside && !consumed { scroll.scrollWheel(with: event) }
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { ownsScroll = false }
        return consumed || !inside
    }
    func browseDay(by offset: Int) {
        guard let agenda, let day = Calendar.current.date(byAdding: .day, value: offset, to: agenda.displayedDay) else { return }
        agenda.selectDay(day); update(agenda)
    }
    @objc func goToToday() {
        guard let agenda else { return }
        agenda.selectDay(nil); update(agenda); scrollToNow()
    }
    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
        if day == calendar.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEEEdMMMM" : "EEEEdMMMMy")
        return format.string(from: date)
    }
    /// Only the event under the pointer is highlighted, including after the timeline scrolls under it.
    func updateHover() {
        let inside = !isHidden && window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } == true
        let hit = inside ? window.flatMap { window in hitTest(superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero) } : nil
        for chip in chips + allDayChips { chip.isHovered = menuEvent.map { chip.event.id == $0 } ?? (chip === hit) }
    }
    func menuWillOpen(_ menu: NSMenu) {}
    func menuDidClose(_ menu: NSMenu) {
        menuEvent = nil; updateHover()
        // Choosing an item outside the card leaves it, as moving there would have.
        guard key != nil, let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        onPointer?(false)
    }
    /// The event's chip shakes when Calendar didn't take an answer to it.
    func answerFailed(_ event: CalendarEvent) {
        NSSound.beep()
        (chips + allDayChips).first { $0.event.id == event.id }?.shake()
    }

    /// `growsFrom` is where it comes out of its tab, in the superview, when that isn't beside the tab's middle.
    func present(key: String, agenda: CalendarAgenda, left: CGFloat, anchorTop: CGFloat, maxBottom: CGFloat, theme: RiseTheme,
                 glides: Bool = false, growsFrom: NSPoint? = nil) {
        let appearing = self.key == nil, switching = self.key != key
        if appearing || switching { slidesDays = false; finishDaySlide() }
        if appearing { CardMotionAnimator.cancelOut(self) }
        self.key = key; self.theme = theme; isHidden = false
        self.agenda = agenda
        if appearing || switching { daySwipe = CalendarDaySwipe(); ownsScroll = false; lastScroll = nil; lastDayScroll = nil; agenda.selectDay(nil) }
        frame.origin.x = left; self.anchorTop = anchorTop; self.maxBottom = maxBottom; tabPoint = growsFrom
        appearance = theme.appearance
        panel.fill = background; dayBody.fill = background
        navigation.fill = background; dayLabel.textColor = theme.text; todayButton.contentTintColor = theme.text
        todayButton.baseColor = theme.text.withAlphaComponent(theme == .dark ? 0.1 : 0.06)
        todayButton.hoverColor = theme.text.withAlphaComponent(theme == .dark ? 0.17 : 0.1)
        todayButton.refreshHoverState()
        KeroLitEdge.apply(to: panel, theme: theme)
        timeline.theme = theme
        divider.fill = theme.text.withAlphaComponent(theme == .dark ? 0.14 : 0.1)
        if switching { events = []; (chips+allDayChips).forEach { $0.removeFromSuperview() }; chips = []; allDayChips = [] }
        update(agenda)
        if appearing { height.settle(); navigationSlide.settle(); if !glides { top.settle() }; render() }
        if appearing && !glides { CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin) }
        // Opens at the hour now, a little of the hour before showing above it.
        if appearing || switching { scrollToNow(); scroll.hideScrollerUntilScrolled() }
        animate()
        clock?.invalidate()
        // The time now moves down the timeline, and events it passes fade.
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        slidesDays = true
        if appearing || switching { agenda.beginBrowsing() }
    }
    func update(_ agenda: CalendarAgenda) {
        guard key != nil else { return }
        let midnight = agenda.displayedDay
        let dayChanged = timeline.midnight != midnight
        if dayChanged { startDaySlide(to: midnight) }
        timeline.midnight = midnight
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        let shown = agenda.displayedEvents.filter { $0.end > midnight && $0.start < tomorrow }
        if shown != events || dayChanged {
            events = shown
            rebuild(timed: shown.filter { !$0.allDay }, allDay: shown.filter(\.allDay))
        }
        let browsing = agenda.browsingDay != nil
        if navigationSlide.target != (browsing ? 1 : 0) {
            ChromeSlideMotion.configure(&navigationSlide, showing: browsing)
            navigationSlide.target = browsing ? 1 : 0
        }
        dayLabel.stringValue = Self.dayTitle(midnight); dayLabel.toolTip = dayLabel.stringValue
        todayButton.isEnabled = browsing
        let waiting = !agenda.displayedHasLoaded
        let text = agenda.error ?? (waiting ? "Loading events" : "")
        message.isHidden = text.isEmpty; retry.isHidden = agenda.error == nil
        if message.stringValue != text { shimmer.cancel(); message.stringValue = text }
        message.textColor = theme.muted; shimmer.baseColor = theme.muted; shimmer.bandColor = theme.text
        retry.contentTintColor = theme.text
        if waiting, agenda.error == nil, agenda.isLoading { if !shimmer.isRunning, window != nil { shimmer.start() } } else { shimmer.cancel() }
        timeline.alphaValue = agenda.error != nil ? 0.35 : 1
        layoutCard(); updateHover(); animate()
    }
    /// Capture the visible composition before rebuilding it. A second swipe can
    /// start from a partially completed slide without flashing an older day.
    private func startDaySlide(to date: Date) {
        guard slidesDays, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !dayClip.bounds.isEmpty, let bitmap = dayClip.bitmapImageRepForCachingDisplay(in: dayClip.bounds) else {
            finishDaySlide(); return
        }
        dayClip.cacheDisplay(in: dayClip.bounds, to: bitmap)
        let image = NSImage(size: dayClip.bounds.size); image.addRepresentation(bitmap)
        finishDaySlide()
        let outgoing = CalendarDayImage(frame: dayClip.bounds)
        outgoing.image = image; outgoing.imageScaling = .scaleAxesIndependently
        outgoing.wantsLayer = true; outgoing.layer?.backgroundColor = background.cgColor
        outgoing.setAccessibilityElement(false)
        dayClip.addSubview(outgoing); outgoingDay = outgoing
        dayDirection = date > timeline.midnight ? 1 : -1
        daySlide.value = 1; daySlide.target = 0; daySlide.velocity = 0
    }
    private func finishDaySlide() {
        outgoingDay?.removeFromSuperview(); outgoingDay = nil
        daySlide.target = 0; daySlide.settle()
        dayBody.setFrameOrigin(.zero)
    }
    /// Where the card comes out of its tab, in its superview: by default its own left edge level
    /// with the middle of the tab beside it.
    private var tabPoint: NSPoint?
    /// The same, in the card's own coordinates.
    private var tabOrigin: CGPoint {
        let point = tabPoint ?? NSPoint(x: frame.minX, y: anchorTop+TabAppearance.height/2)
        return CGPoint(x: point.x-frame.minX, y: point.y-frame.minY)
    }
    /// Plays the way in again, for the motion tester.
    func replayMotion() {
        guard key != nil, !isHidden else { return }
        CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin)
    }
    /// Goes with the motion picked with Develop ▸ Card Motion Tester, or at once with `animated: false`.
    func dismiss(animated: Bool = true) {
        let wasShown = key != nil
        key = nil; link?.invalidate(); link = nil; clock?.invalidate(); clock = nil; shimmer.cancel()
        slidesDays = false; finishDaySlide(); agenda?.endBrowsing()
        height.settle(); top.settle(); navigationSlide.target = 0; navigationSlide.settle(); daySwipe = CalendarDaySwipe(); ownsScroll = false; lastScroll = nil; lastDayScroll = nil
        if wasShown { agenda?.selectDay(nil) }
        guard animated, wasShown else { isHidden = true; return }
        CardMotionAnimator.animateOut(self, CardMotion.selected, tab: tabOrigin) { [weak self] in
            if self?.key == nil { self?.isHidden = true }
        }
    }
    private func timeText(_ event: CalendarEvent) -> String {
        let formatter = DateIntervalFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
    private func rebuild(timed: [CalendarEvent], allDay: [CalendarEvent]) {
        (chips+allDayChips).forEach { $0.removeFromSuperview() }
        func chip(_ event: CalendarEvent, time: String?) -> CalendarEventChip {
            let chip = CalendarEventChip(event, time: time)
            chip.onOpen = { [weak self] in self?.onOpen?(event) }
            chip.onMenu = { [weak self] in
                guard let self, let menu = menuFor?(event) else { return nil }
                menu.delegate = self; menuEvent = event.id; updateHover(); return menu
            }
            chip.applyTheme(theme, panel: background); return chip
        }
        chips = timed.map { chip($0, time: timeText($0)) }
        chips.forEach(timeline.addSubview)
        timeline.raiseNow()
        allDayChips = allDay.prefix(allDay.count > 2 ? 1 : 2).map { chip($0, time: nil) }
        allDayChips.forEach(self.allDay.addSubview)
        moreAllDay.stringValue = allDay.count > 2 ? "\(allDay.count-1) more all-day events" : ""
        tick()
    }
    private func tick() {
        let now = Date()
        for chip in chips + allDayChips { chip.isPast = chip.event.end <= now }
        timeline.layoutNow()
    }
    private var allDayRows: Int { allDayChips.count + (moreAllDay.stringValue.isEmpty ? 0 : 1) }
    private var allDayHeaderHeight: CGFloat { allDayRows == 0 ? 0 : CGFloat(allDayRows)*(Self.allDayHeight+Self.allDayGap)+Self.allDayGap+4 }
    private func layoutCard() {
        height.target = min(Self.preferredHeight+allDayHeaderHeight, max(120, maxBottom-8))
        top.target = max(8, min(anchorTop, maxBottom-height.target))
        timeline.setFrameSize(NSSize(width: Self.width, height: CalendarTimeline.contentHeight))
        let columnsWidth = Self.width-CalendarTimeline.labelWidth-CalendarTimeline.trailing
        let minimum = 18/CalendarTimeline.hourHeight*60
        let placed = Dictionary(uniqueKeysWithValues: CalendarSchedule.columns(events, minimumMinutes: minimum).map { ($0.event.id, $0) })
        for chip in chips {
            guard let place = placed[chip.event.id] else { chip.isHidden = true; continue }
            chip.isHidden = false
            let width = (columnsWidth-CGFloat(place.columns-1)*2)/CGFloat(place.columns)
            // An event across midnight runs off the end of the day.
            let top = timeline.y(chip.event.start), bottom = min(timeline.y(chip.event.end), CalendarTimeline.dayHeight+CalendarTimeline.chipGap)
            // As far below the hour line it starts on as above the one it ends on.
            let start = top+CalendarTimeline.lineWidth+CalendarTimeline.chipGap
            chip.frame = NSRect(x: (CalendarTimeline.labelWidth+CGFloat(place.column)*(width+2)).rounded(), y: start,
                                width: width.rounded(), height: max(18, bottom-CalendarTimeline.chipGap-start))
        }
        var y = Self.allDayGap+2
        for chip in allDayChips {
            // Inset from the card's sides as far as the timeline's events are from its right.
            chip.frame = NSRect(x: CalendarTimeline.trailing, y: y, width: Self.width-2*CalendarTimeline.trailing, height: Self.allDayHeight)
            y += Self.allDayHeight+Self.allDayGap
        }
        moreAllDay.textColor = theme.muted
        moreAllDay.frame = NSRect(x: 14, y: y+3, width: Self.width-28, height: 16)
        timeline.layoutNow()
        render()
    }
    private func scrollToNow() {
        layoutCard()
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let y = max(0, timeline.y(hour)-16)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, CalendarTimeline.contentHeight-scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func render() {
        let origin = scroll.contentView.bounds.origin
        let navigationHeight = Self.navigationHeight*navigationSlide.value
        // Its spring can travel above the clipping edge on the way out, but
        // that mustn't take space away from the all-day rows or timeline.
        let navigationSpace = max(0, navigationHeight)
        let shownHeight = max(0, min(height.value+navigationSpace, maxBottom-8))
        frame = NSRect(x: frame.minX, y: max(8, min(top.value, maxBottom-shownHeight)), width: Self.width, height: shownHeight)
        panel.frame = bounds; clip.frame = bounds
        let header = allDayHeaderHeight+navigationSpace
        navigation.frame = NSRect(x: 0, y: navigationHeight-Self.navigationHeight, width: Self.width, height: Self.navigationHeight)
        navigation.isHidden = navigationSlide.value == 0 && navigationSlide.target == 0
        dayLabel.frame = NSRect(x: 12, y: 6, width: Self.width-100, height: 17)
        todayButton.frame = NSRect(x: Self.width-80, y: 3, width: 68, height: 22)
        dayClip.frame = NSRect(x: 0, y: navigationSpace, width: Self.width, height: max(0, bounds.height-navigationSpace))
        dayBody.frame = dayClip.bounds.offsetBy(dx: dayDirection*Self.width*daySlide.value, dy: 0)
        if let outgoingDay { outgoingDay.frame.origin.x = dayDirection*Self.width*(daySlide.value-1) }
        allDay.frame = NSRect(x: 0, y: 0, width: Self.width, height: allDayHeaderHeight); allDay.isHidden = allDayHeaderHeight == 0
        divider.frame = NSRect(x: 0, y: allDayHeaderHeight-0.5, width: Self.width, height: 0.5); divider.isHidden = header == 0
        scroll.frame = NSRect(x: 0, y: allDayHeaderHeight, width: Self.width, height: max(0, bounds.height-header))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(origin.y, CalendarTimeline.contentHeight-scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        let textWidth = Self.width-48
        let size = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100)) ?? .zero
        let middle = allDayHeaderHeight+(bounds.height-header)/2
        message.frame = NSRect(x: 24, y: middle-ceil(size.height)/2-(retry.isHidden ? 0 : 12), width: textWidth, height: ceil(size.height))
        shimmer.frame = message.bounds
        retry.frame = NSRect(x: (Self.width-100)/2, y: message.frame.maxY+6, width: 100, height: 22)
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
    }
    @objc private func scrolled() { updateHover() }
    @objc private func retryLoading() { onRetry?() }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { height.settle(); top.settle(); navigationSlide.settle(); finishDaySlide(); render(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        height.step(dt); top.step(dt); navigationSlide.step(dt); daySlide.step(dt)
        if daySlide.isResting(within: 0.001) { finishDaySlide() }
        if height.isResting(within: 0.05), top.isResting(within: 0.05), navigationSlide.isResting(within: 0.001), outgoingDay == nil {
            link.invalidate(); self.link = nil; height.settle(); top.settle(); navigationSlide.settle()
        }
        render()
    }
}

/// The outgoing day is only a picture; its old events must never take a click.
private final class CalendarDayImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
