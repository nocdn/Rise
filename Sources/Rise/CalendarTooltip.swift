import AppKit

/// An event on the card's timeline, or an all-day event above it, in the theme's accent.
final class CalendarEventChip: NSButton {
    let event: CalendarEvent
    private let name = NSTextField(labelWithString: "")
    var onOpen: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isPast = false { didSet { if isPast != oldValue { alphaValue = isPast ? 0.55 : 1 } } }
    private var theme = RiseTheme.neutral, panel = NSColor.white
    override var isFlipped: Bool { true }
    init(_ event: CalendarEvent, time: String?) {
        self.event = event
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(open); wantsLayer = true
        name.stringValue = event.title; name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
        addSubview(name)
        toolTip = time.map { event.title+"\n"+$0 } ?? event.title
        setAccessibilityLabel(event.title); setAccessibilityValue(time ?? "All day")
    }
    required init?(coder: NSCoder) { fatalError() }
    static func colors(_ theme: RiseTheme, panel: NSColor, hovered: Bool = false) -> (fill: NSColor, border: NSColor, text: NSColor) {
        let dark = theme == .dark, base: CGFloat = dark ? 0.42 : 0.3
        let fill = panel.blended(withFraction: base+(hovered ? 0.1 : 0), of: theme.accent) ?? theme.accent
        let border = panel.blended(withFraction: dark ? 0.62 : 0.55, of: theme.accent) ?? theme.accent
        return (fill, border, dark ? NSColor.white.withAlphaComponent(0.92) : theme.text)
    }
    func applyTheme(_ theme: RiseTheme, panel: NSColor) {
        self.theme = theme; self.panel = panel
        name.textColor = Self.colors(theme, panel: panel).text; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let compact = bounds.height < 22
        name.font = .systemFont(ofSize: compact ? 11 : 12.5, weight: .medium)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: name.font!))
        let y = compact ? max(0, (bounds.height-line)/2) : 4
        name.frame = NSRect(x: 6, y: y, width: max(0, bounds.width-10), height: min(line, bounds.height))
        name.isHidden = bounds.height < 9
    }
    override func draw(_ dirtyRect: NSRect) {
        let colors = Self.colors(theme, panel: panel, hovered: isHovered)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        colors.fill.setFill(); path.fill()
        colors.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc private func open() { onOpen?() }
}

/// Today and tomorrow, hour by hour from midnight: lines, hour labels and the time now.
final class CalendarTimeline: FlippedView {
    static let hourHeight: CGFloat = 42, labelWidth: CGFloat = 54, trailing: CGFloat = 6
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
    static var contentHeight: CGFloat { 48*hourHeight+8 }
    func y(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(midnight)/3600)*Self.hourHeight }
    /// Above the events, as in Calendar.
    func raiseNow() { [now, dot].forEach { $0.removeFromSuperview(); addSubview($0) } }
    func layoutNow() {
        let color = theme == .dark ? NSColor.white : theme.selectedText
        now.layer?.backgroundColor = color.cgColor; dot.layer?.backgroundColor = color.cgColor
        let y = y(Date()).rounded()
        now.frame = NSRect(x: Self.labelWidth-4, y: y-0.75, width: bounds.width-Self.labelWidth+4-Self.trailing, height: 1.5)
        dot.frame = NSRect(x: Self.labelWidth-8, y: y-4, width: 8, height: 8)
    }
    override func draw(_ dirtyRect: NSRect) {
        let line = theme.text.withAlphaComponent(theme == .dark ? 0.14 : 0.1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.muted]
        for hour in 0..<48 {
            let y = CGFloat(hour)*Self.hourHeight
            guard y+Self.hourHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            line.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: 1/(window?.backingScaleFactor ?? 2)).fill()
            guard let date = Calendar.current.date(byAdding: .hour, value: hour, to: midnight) else { continue }
            (Self.hourFormat.string(from: date).uppercased() as NSString).draw(at: NSPoint(x: 8, y: y+6), withAttributes: attributes)
        }
    }
}

/// The same surface and positioning springs as the Gmail card, over a timeline of today and
/// tomorrow that opens at the hour now.
@MainActor final class CalendarTooltip: FlippedView {
    static let width: CGFloat = 264, preferredHeight: CGFloat = 268
    static let allDayHeight: CGFloat = 22, allDayGap: CGFloat = 4
    let scroll = NSScrollView()
    let timeline = CalendarTimeline(frame: .zero)
    private let panel = Surface(radius: FindBar.radius)
    private let clip = FlippedView(), allDay = FlippedView(), divider = Surface()
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
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.verticalScroller = GmailScroller(); scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.documentView = timeline; scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        message.font = .systemFont(ofSize: 12); message.alignment = .center
        message.maximumNumberOfLines = 2; message.lineBreakMode = .byWordWrapping
        shimmer.configureForSmartRename(field: message)
        retry.isBordered = false; retry.font = .systemFont(ofSize: 12, weight: .medium)
        retry.target = self; retry.action = #selector(retryLoading)
        moreAllDay.font = .systemFont(ofSize: 11, weight: .medium)
        clip.addSubview(scroll); clip.addSubview(allDay); clip.addSubview(divider)
        clip.addSubview(message); clip.addSubview(retry)
        allDay.addSubview(moreAllDay)
        panel.addSubview(clip); addSubview(panel)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        top.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true); updateHover() }
    override func mouseExited(with event: NSEvent) { onPointer?(false); updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    /// Only the event under the pointer is highlighted, including after the timeline scrolls under it.
    func updateHover() {
        let inside = !isHidden && window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } == true
        let hit = inside ? window.flatMap { window in hitTest(superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero) } : nil
        for chip in chips + allDayChips { chip.isHovered = chip === hit }
    }

    func present(key: String, agenda: CalendarAgenda, left: CGFloat, anchorTop: CGFloat, maxBottom: CGFloat, theme: RiseTheme, glides: Bool = false) {
        let appearing = self.key == nil, switching = self.key != key
        self.key = key; self.theme = theme; isHidden = false
        frame.origin.x = left; self.anchorTop = anchorTop; self.maxBottom = maxBottom
        appearance = theme.appearance
        panel.fill = background
        panel.layer?.borderColor = theme.border.cgColor
        timeline.theme = theme
        divider.fill = theme.text.withAlphaComponent(theme == .dark ? 0.14 : 0.1)
        if switching { events = []; (chips+allDayChips).forEach { $0.removeFromSuperview() }; chips = []; allDayChips = [] }
        update(agenda)
        if appearing { height.settle(); if !glides { top.settle() }; render() }
        // Opens at the hour now, a little of the hour before showing above it.
        if appearing || switching { scrollToNow() }
        animate()
        clock?.invalidate()
        // The time now moves down the timeline, and events it passes fade.
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func update(_ agenda: CalendarAgenda) {
        guard key != nil else { return }
        let midnight = Calendar.current.startOfDay(for: Date())
        let dayChanged = timeline.midnight != midnight
        timeline.midnight = midnight
        let shown = agenda.events.filter { $0.end > midnight }
        if shown != events || dayChanged {
            events = shown
            let today = Calendar.current.date(byAdding: .day, value: 1, to: midnight) ?? midnight
            rebuild(timed: shown.filter { !$0.allDay }, allDay: shown.filter { $0.allDay && $0.start < today })
        }
        let waiting = !agenda.hasLoaded
        let text = agenda.error ?? (waiting ? "Loading events" : "")
        message.isHidden = text.isEmpty; retry.isHidden = agenda.error == nil
        if message.stringValue != text { shimmer.cancel(); message.stringValue = text }
        message.textColor = theme.muted; shimmer.baseColor = theme.muted; shimmer.bandColor = theme.text
        retry.contentTintColor = theme.text
        if waiting, agenda.error == nil, agenda.isLoading { if !shimmer.isRunning, window != nil { shimmer.start() } } else { shimmer.cancel() }
        timeline.alphaValue = agenda.error != nil ? 0.35 : 1
        layoutCard(); updateHover(); animate()
    }
    func dismiss() {
        key = nil; isHidden = true; link?.invalidate(); link = nil; clock?.invalidate(); clock = nil; shimmer.cancel()
        height.settle(); top.settle()
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
    private var headerHeight: CGFloat { allDayRows == 0 ? 0 : CGFloat(allDayRows)*(Self.allDayHeight+Self.allDayGap)+Self.allDayGap+4 }
    private func layoutCard() {
        height.target = min(Self.preferredHeight+headerHeight, max(120, maxBottom-8))
        top.target = max(8, min(anchorTop, maxBottom-height.target))
        timeline.setFrameSize(NSSize(width: Self.width, height: CalendarTimeline.contentHeight))
        let columnsWidth = Self.width-CalendarTimeline.labelWidth-CalendarTimeline.trailing
        let minimum = 18/CalendarTimeline.hourHeight*60
        let placed = Dictionary(uniqueKeysWithValues: CalendarSchedule.columns(events, minimumMinutes: minimum).map { ($0.event.id, $0) })
        for chip in chips {
            guard let place = placed[chip.event.id] else { chip.isHidden = true; continue }
            chip.isHidden = false
            let width = (columnsWidth-CGFloat(place.columns-1)*2)/CGFloat(place.columns)
            let top = timeline.y(chip.event.start), bottom = timeline.y(chip.event.end)
            chip.frame = NSRect(x: CalendarTimeline.labelWidth+CGFloat(place.column)*(width+2), y: top+1,
                                width: width, height: max(18, bottom-top-2)).integral
        }
        var y = Self.allDayGap+2
        for chip in allDayChips {
            chip.frame = NSRect(x: 8, y: y, width: Self.width-16, height: Self.allDayHeight); y += Self.allDayHeight+Self.allDayGap
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
        frame = NSRect(x: frame.minX, y: top.value, width: Self.width, height: max(0, height.value))
        panel.frame = bounds; clip.frame = bounds
        let header = headerHeight
        allDay.frame = NSRect(x: 0, y: 0, width: Self.width, height: header); allDay.isHidden = header == 0
        divider.frame = NSRect(x: 0, y: header-0.5, width: Self.width, height: 0.5); divider.isHidden = header == 0
        scroll.frame = NSRect(x: 0, y: header, width: Self.width, height: max(0, bounds.height-header))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(origin.y, CalendarTimeline.contentHeight-scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        let textWidth = Self.width-48
        let size = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100)) ?? .zero
        let middle = header+(bounds.height-header)/2
        message.frame = NSRect(x: 24, y: middle-ceil(size.height)/2-(retry.isHidden ? 0 : 12), width: textWidth, height: ceil(size.height))
        shimmer.frame = message.bounds
        retry.frame = NSRect(x: (Self.width-100)/2, y: message.frame.maxY+6, width: 100, height: 22)
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
    }
    @objc private func scrolled() { updateHover() }
    @objc private func retryLoading() { onRetry?() }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { height.settle(); top.settle(); render(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        height.step(dt); top.step(dt)
        if height.isResting(within: 0.05), top.isResting(within: 0.05) {
            link.invalidate(); self.link = nil; height.settle(); top.settle()
        }
        render()
    }
}
