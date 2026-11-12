import AppKit

/// One exchange: the pages it was asked about and the question, right-aligned, then the answer.
@MainActor final class AIChatTurnView: FlippedView {
    let id: UUID
    let chips: [AIChatPageChip]
    let bubble: AIChatBubble
    let answer: AIChatAnswerView
    /// Where the question's bubble is drawn from its place, while it lifts off the composer.
    var bubbleOffset = CGPoint.zero { didSet { if bubbleOffset != oldValue { placeBubble() } } }
    /// How far the pages and question have faded in as they arrive.
    var arrival: CGFloat = 1 { didSet { if arrival != oldValue { chips.forEach { $0.alphaValue = arrival } } } }
    private var bubbleFrame = NSRect.zero
    init(_ turn: AIChatTurn, thinking: Bool) {
        id = turn.id
        chips = turn.pages.map { AIChatPageChip($0, removable: false) }
        bubble = AIChatBubble(turn.question)
        answer = AIChatAnswerView(thinking: thinking)
        super.init(frame: .zero)
        (chips as [NSView] + [bubble, answer]).forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyColors(_ colors: AIChatColors) {
        chips.forEach { $0.applyColors(colors) }; bubble.applyColors(colors); answer.applyColors(colors)
    }
    /// Lays the exchange out `width` wide and returns its height.
    @discardableResult func place(width: CGFloat, composerWidth: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let right = width-AIChatStyle.trailing
        if !chips.isEmpty {
            // Right-aligned, as many to a row as fit.
            var rowRight = right
            for chip in chips {
                let size = AIChatStyle.chipSize
                if rowRight-size.width < AIChatStyle.leading && rowRight < right { y += size.height+8; rowRight = right }
                chip.frame = NSRect(x: rowRight-size.width, y: y, width: size.width, height: size.height)
                rowRight -= size.width+8
            }
            y += AIChatStyle.chipSize.height+AIChatStyle.chipGap
        }
        let size = bubble.fit(maxWidth: floor(composerWidth*AIChatStyle.bubbleWidthFraction))
        bubbleFrame = NSRect(x: right-size.width, y: y, width: size.width, height: size.height)
        placeBubble()
        y += size.height+AIChatStyle.thoughtGap
        let answerWidth = width-AIChatStyle.leading-AIChatStyle.textTrailing
        let answerHeight = answer.height(for: answerWidth)
        answer.frame = NSRect(x: AIChatStyle.leading, y: y, width: answerWidth, height: answerHeight)
        return y+answerHeight
    }
    var bubblePlace: NSRect { bubbleFrame }
    private func placeBubble() { bubble.frame = bubbleFrame.offsetBy(dx: bubbleOffset.x, dy: bubbleOffset.y) }
}

/// Dia's chat panel, inside its docked card: New Chat and Close above the conversation, which
/// scrolls under a composer floating at the foot. Asking lifts the question off the composer up
/// to the top of the panel; the answer plays out under it with the find bar's token effect.
@MainActor final class AIChatView: FlippedView {
    let newChatButton = ChromeButton(symbol: "square.and.pencil", size: 16, title: "New Chat", action: {})
    let closeButton = ChromeButton(symbol: "xmark", size: 13, title: "Close Chat (⌘E)", action: {})
    private let hairline = Surface()
    let scroll = NSScrollView()
    private let stack = FlippedView()
    let composer = AIChatComposer()
    private(set) var turns: [AIChatTurn] = []
    private var turnViews: [AIChatTurnView] = []
    private var colors = AIChatColors(.neutral)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    /// A question on its way up from the composer: from where, and the scroll it brings with it.
    private var lift = MotionSpring(1)
    private var liftPath: (turn: UUID, start: NSRect, scrollFrom: CGFloat, scrollTo: CGFloat)?
    private var answerTask: Task<Void, Never>?
    var isAnswering: Bool { answerTask != nil }

    /// Pages added from the + menu, and the page in front, which is attached until it's taken
    /// off or already in the conversation.
    private var addedPages: [AIChatAttachment] = []
    private var currentPage: AIChatAttachment?
    private var removedPageURL: URL?

    var onClose: (() -> Void)?
    /// Hands the keyboard back to the page.
    var onLeave: (() -> Void)?
    /// What the model needs from a page as the question is sent.
    var snapshot: ((AIChatAttachment) async -> PageAssistant.Page?)?
    /// The model's answer to the conversation, as text so far.
    var respond: (([[String: Any]]) -> AsyncThrowingStream<String, Error>)?
    /// Open pages the + menu offers, and the More menu's provider choice.
    var openPages: (() -> [AIChatAttachment])?
    var providerMenu: (() -> NSMenuItem)?
    var modelName: (() -> String)?
    var pasteboard = NSPasteboard.general

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed; scroll.horizontalScrollElasticity = .none
        scroll.documentView = stack
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHairline() }
        }
        newChatButton.actionBlock = { [weak self] in self?.newChat() }
        closeButton.actionBlock = { [weak self] in self?.onClose?() }
        newChatButton.image = AIChatComposer.symbol("square.and.pencil", size: 16)
        closeButton.image = AIChatComposer.symbol("xmark", size: 14)
        composer.onSend = { [weak self] question in self?.send(question) }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onRemove = { [weak self] page in self?.remove(page) }
        composer.onMotion = { [weak self] in self?.animate() }
        composer.onEscape = { [weak self] in
            guard let self else { return }
            if self.isAnswering { self.stop() } else { self.onLeave?() }
        }
        composer.plusButton.makeMenu = { [weak self] in self?.makeAddMenu() }
        composer.moreButton.makeMenu = { [weak self] in self?.makeMoreMenu() }
        composer.cameraButton.isEnabled = false; composer.cameraButton.toolTip = "Screenshots aren’t supported yet"
        [scroll, hairline, newChatButton, closeButton, composer].forEach(addSubview)
        lift.configure(response: 0.28, bounce: 0)
        updateHeader()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyColors(_ colors: AIChatColors) {
        guard colors != self.colors else { return }
        self.colors = colors
        hairline.fill = colors.hairline
        [newChatButton, closeButton].forEach { $0.hoverColor = colors.hover }
        updateHeader()
        composer.applyColors(colors)
        turnViews.forEach { $0.applyColors(colors) }
        needsLayout = true
    }
    private func updateHeader() {
        // New Chat is pale until there's a chat to leave.
        newChatButton.contentTintColor = turns.isEmpty ? colors.headerIcon.withAlphaComponent(0.5) : colors.headerIcon
        newChatButton.isEnabled = !turns.isEmpty
        closeButton.contentTintColor = colors.headerIcon
        composer.hasConversation = !turns.isEmpty
    }
    private func updateHairline() {
        hairline.alphaValue = min(1, max(0, scroll.contentView.bounds.minY/6))
    }

    // MARK: Pages

    /// The page in front changed, or its title or address did.
    func setCurrentPage(_ page: AIChatAttachment?) {
        if page?.url != currentPage?.url { removedPageURL = nil }
        currentPage = page
        refreshAttachments()
    }
    private func refreshAttachments() {
        var pages = addedPages
        let asked = turns.flatMap(\.pages)
        if let page = currentPage, page.url != removedPageURL, !asked.contains(where: page.isSamePage), !pages.contains(where: page.isSamePage) {
            pages.append(page)
        }
        composer.setAttachments(pages)
    }
    private func remove(_ page: AIChatAttachment) {
        if let current = currentPage, page.isSamePage(as: current), !addedPages.contains(where: page.isSamePage) { removedPageURL = page.url }
        addedPages.removeAll { $0.isSamePage(as: page) }
        refreshAttachments(); composer.focus()
    }
    private func makeAddMenu() -> NSMenu {
        let menu = NSMenu()
        let attached = composer.attachments
        let pages = (openPages?() ?? []).filter { page in !attached.contains(where: page.isSamePage) }
        let header = NSMenuItem(title: pages.isEmpty ? "No Other Pages Open" : "Add an Open Page", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        for page in pages.prefix(20) {
            let item = Self.menuItem(page.title.isEmpty ? page.subtitle : page.title) { [weak self] in
                guard let self else { return }
                if let removed = self.removedPageURL, page.url == removed { self.removedPageURL = nil }
                self.addedPages.append(page); self.refreshAttachments(); self.composer.focus()
            }
            if let favicon = page.favicon?.copy() as? NSImage { favicon.size = NSSize(width: 16, height: 16); item.image = favicon }
            menu.addItem(item)
        }
        return menu
    }
    private static func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        let handler = MenuAction(action); item.target = handler; item.representedObject = handler
        return item
    }
    private func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        if let name = modelName?() {
            let model = NSMenuItem(title: name, action: nil, keyEquivalent: ""); model.isEnabled = false
            menu.addItem(model)
        }
        if let provider = providerMenu?() { menu.addItem(provider) }
        menu.addItem(.separator())
        let newChat = Self.menuItem("New Chat") { [weak self] in self?.newChat() }
        newChat.isEnabled = !turns.isEmpty
        menu.addItem(newChat)
        return menu
    }

    // MARK: Conversation

    func newChat() {
        cancelAnswer()
        turns = []; turnViews.forEach { $0.removeFromSuperview() }; turnViews = []
        addedPages = []; removedPageURL = nil; liftPath = nil
        composer.clear(); composer.isAnswering = false
        refreshAttachments(); updateHeader()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        needsLayout = true; composer.focus()
    }
    func send(_ question: String) {
        guard !isAnswering else { return }
        let turn = AIChatTurn(question: question, pages: composer.attachments)
        let history = turns
        turns.append(turn)
        let view = AIChatTurnView(turn, thinking: true)
        view.applyColors(colors)
        configure(view, for: turn.id)
        stack.addSubview(view); turnViews.append(view)
        addedPages = []
        let start = composer.textFrame
        composer.clear(); composer.isAnswering = true
        refreshAttachments(); updateHeader()
        layOutConversation()
        liftOff(view, from: start)
        view.answer.beginThinking()
        ask(turn, history: history, in: view)
    }
    private func configure(_ view: AIChatTurnView, for id: UUID) {
        view.answer.onCopy = { [weak self, weak view] in
            guard let self, let view else { return }
            self.pasteboard.clearContents(); self.pasteboard.setString(view.answer.textView.string, forType: .string)
        }
        view.answer.onRegenerate = { [weak self] in self?.regenerate(id) }
    }
    private func ask(_ turn: AIChatTurn, history: [AIChatTurn], in view: AIChatTurnView) {
        let snapshot = self.snapshot, respond = self.respond
        answerTask = Task { [weak self, weak view] in
            var current = turn
            if current.snapshots.isEmpty {
                for page in turn.pages {
                    let read = await snapshot?(page)
                    current.snapshots.append(read ?? PageAssistant.Page(title: page.title, url: page.url?.absoluteString ?? "", selection: "", text: ""))
                }
            }
            guard !Task.isCancelled, let self else { return }
            if let index = self.turns.firstIndex(where: { $0.id == turn.id }) { self.turns[index].snapshots = current.snapshots }
            guard let respond else { self.finish(turn.id, text: "", error: PageAssistant.Failure.service("There’s no model to ask.")); return }
            var text = ""
            do {
                for try await token in respond(AIChatPrompt.messages(history: history, current: current)) {
                    guard !Task.isCancelled else { return }
                    text += token
                    if !token.isEmpty { view?.answer.receive(text); self.layOutConversation(); self.animate() }
                }
                guard !Task.isCancelled else { return }
                self.finish(turn.id, text: text, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(turn.id, text: text, error: error)
            }
        }
    }
    private func finish(_ id: UUID, text: String, error: Error?) {
        answerTask = nil; composer.isAnswering = false
        guard let index = turns.firstIndex(where: { $0.id == id }), let view = turnViews.first(where: { $0.id == id }) else { return }
        turns[index].answer = text
        if let error {
            turns[index].failed = text.isEmpty
            view.answer.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        } else if text.isEmpty {
            turns[index].failed = true
            view.answer.fail("No answer came back.")
        } else { view.answer.finish() }
        updateRegenerate(); layOutConversation(); animate()
    }
    /// Stops the answer where it is.
    func stop() {
        guard isAnswering, let turn = turns.last, let view = turnViews.last else { return }
        cancelAnswer()
        let text = view.answer.markdown
        if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index].answer = text }
        if text.isEmpty { turns[turns.count-1].failed = true; view.answer.fail("Stopped.") } else { view.answer.finish() }
        updateRegenerate(); layOutConversation(); animate()
    }
    private func cancelAnswer() { answerTask?.cancel(); answerTask = nil; composer.isAnswering = false }
    /// Asks the last question again, with the pages as they read then.
    private func regenerate(_ id: UUID) {
        guard !isAnswering, let last = turns.last, last.id == id, let old = turnViews.last else { return }
        turns.removeLast(); old.removeFromSuperview(); turnViews.removeLast()
        var turn = AIChatTurn(question: last.question, pages: last.pages)
        turn.snapshots = last.snapshots
        turns.append(turn)
        let view = AIChatTurnView(turn, thinking: true)
        view.applyColors(colors); configure(view, for: turn.id)
        stack.addSubview(view); turnViews.append(view)
        composer.isAnswering = true
        layOutConversation(); view.answer.beginThinking()
        ask(turn, history: Array(turns.dropLast()), in: view)
    }
    private func updateRegenerate() {
        for (index, view) in turnViews.enumerated() { view.answer.canRegenerate = index == turnViews.count-1 }
    }

    // MARK: Layout and motion

    private var composerWidth: CGFloat { max(0, bounds.width-2*AIChatStyle.composerInset) }
    override func layout() {
        super.layout()
        let width = bounds.width
        newChatButton.frame = NSRect(x: 13.5, y: AIChatStyle.headerIconMid-14, width: 28, height: 28)
        closeButton.frame = NSRect(x: width-41, y: AIChatStyle.headerIconMid-14, width: 28, height: 28)
        hairline.frame = NSRect(x: 0, y: AIChatStyle.headerHeight-0.5, width: width, height: 0.5)
        scroll.frame = NSRect(x: 0, y: AIChatStyle.headerHeight, width: width, height: max(0, bounds.height-AIChatStyle.headerHeight))
        placeComposer()
        layOutConversation()
    }
    private func placeComposer() {
        let height = composer.currentHeight
        composer.frame = NSRect(x: AIChatStyle.composerInset, y: bounds.height-AIChatStyle.composerInset-height, width: composerWidth, height: height)
    }
    /// The exchanges top to bottom, with room under the last so it can sit at the top of the
    /// panel and so the end of it can scroll up clear of the composer.
    private func layOutConversation() {
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        var y = AIChatStyle.contentTop, lastTop: CGFloat = 0
        for view in turnViews {
            let height = view.place(width: width, composerWidth: composerWidth)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            lastTop = y; y += height+AIChatStyle.turnGap
        }
        let bottom = turnViews.isEmpty ? 0 : y-AIChatStyle.turnGap+composer.targetHeight+AIChatStyle.composerInset+24
        let viewport = scroll.contentSize.height
        let height = max(viewport, bottom, turnViews.isEmpty ? 0 : lastTop-AIChatStyle.contentTop+viewport)
        if stack.frame.size != NSSize(width: width, height: height) { stack.frame = NSRect(x: 0, y: 0, width: width, height: height) }
        if let path = liftPath { placeLift(path) }
        updateHairline()
    }
    /// Sends the question's bubble up from just above the composer to its place, scrolling the
    /// conversation so it lands at the top, on Dia's measured lift (90% of the way in 0.17 s).
    private func liftOff(_ view: AIChatTurnView, from start: NSRect) {
        let target = max(0, view.frame.minY-AIChatStyle.contentTop)
        let from = scroll.contentView.bounds.minY
        let bubble = view.bubblePlace
        let composerTop = composer.frame.minY
        let startFrame = NSRect(x: bubble.minX, y: min(composerTop-12-bubble.height, start.minY), width: bubble.width, height: bubble.height)
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            scroll(to: target); return
        }
        liftPath = (view.id, startFrame, from, target)
        lift.value = 0; lift.velocity = 0; lift.target = 1
        view.arrival = 0
        placeLift(liftPath!)
        animate()
    }
    private func placeLift(_ path: (turn: UUID, start: NSRect, scrollFrom: CGFloat, scrollTo: CGFloat)) {
        guard let view = turnViews.first(where: { $0.id == path.turn }) else { liftPath = nil; return }
        let p = CGFloat(min(1.2, max(0, lift.value)))
        let scrollY = path.scrollFrom+(path.scrollTo-path.scrollFrom)*p
        scroll(to: scrollY)
        // In the panel: where the bubble rests, and where it lands once the scroll is done.
        let resting = view.bubblePlace.offsetBy(dx: 0, dy: view.frame.minY+AIChatStyle.headerHeight)
        let natural = resting.offsetBy(dx: 0, dy: -scrollY)
        let landed = resting.offsetBy(dx: 0, dy: -path.scrollTo)
        let visual = NSPoint(x: path.start.minX+(landed.minX-path.start.minX)*p, y: path.start.minY+(landed.minY-path.start.minY)*p)
        view.bubbleOffset = CGPoint(x: visual.x-natural.minX, y: visual.y-natural.minY)
        view.bubble.alphaValue = min(1, p*5)
        view.arrival = min(1, p*3)
    }
    private func scroll(to y: CGFloat) {
        let limit = max(0, stack.frame.height-scroll.contentSize.height)
        let point = NSPoint(x: 0, y: min(max(0, y), limit))
        guard scroll.contentView.bounds.origin != point else { return }
        scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
    }

    func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    /// Everything where it's going, for a panel that isn't animating.
    func settle() {
        link?.invalidate(); link = nil
        composer.settle(); lift.value = 1; lift.velocity = 0
        if let path = liftPath { placeLift(path); liftPath = nil }
        turnViews.forEach { $0.bubbleOffset = .zero; $0.bubble.alphaValue = 1; $0.arrival = 1; $0.answer.revealAll() }
        needsLayout = true
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        composer.step(dt); lift.step(dt)
        var moving = false
        for view in turnViews where view.answer.step(dt, now: now) { moving = true }
        placeComposer(); layOutConversation()
        if liftPath != nil && lift.isResting(within: 0.001) {
            lift.value = 1; if let path = liftPath { placeLift(path) }; liftPath = nil
        }
        if !moving && composer.isResting && liftPath == nil { link.invalidate(); self.link = nil }
    }
}

/// The chat's card, docked at the window's right edge like DevTools and on their springs.
@MainActor final class AIChatPanel {
    var slide = MotionSpring(0)
    var link: CADisplayLink?
    var lastTick: CFTimeInterval?
    let shadow = PageSurface(color: NSColor(hex: 0xFAFAFA), radius: PageAppearance.radius)
    let clip = PageSurface(color: NSColor(hex: 0xFAFAFA), radius: PageAppearance.radius)
    let view = AIChatView()
    /// In the gap between the page and the chat: dragged, it resizes them.
    let handle = SplitHandle()
    var chosenWidth: CGFloat?
    private var theme: RiseTheme?
    var isOpen: Bool { slide.target > 0 }
    var progress: CGFloat { CGFloat(slide.value) }
    init() {
        shadow.layer?.cornerCurve = .continuous; clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true; clip.clipsToBounds = true
        clip.addSubview(view); shadow.addSubview(clip)
        shadow.isHidden = true; handle.isHidden = true
        handle.toolTip = "Drag to resize the chat"; handle.setAccessibilityLabel("Chat divider")
    }
    /// Dia's 480 pt, or as dragged, never under its 320 pt nor leaving the page less than DevTools do.
    func width(room: CGFloat) -> CGFloat {
        let widest = max(AIChatStyle.minimumWidth, room-DevToolsPanel.minimumPageWidth-PageAppearance.inset)
        return min(max(chosenWidth ?? AIChatStyle.defaultWidth, AIChatStyle.minimumWidth), widest)
    }
    func applyTheme(_ theme: RiseTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        let colors = AIChatColors(theme)
        shadow.fill = colors.panel; clip.fill = colors.panel
        shadow.keroShadows = theme == .dark ? .dark : .light
        handle.applyTheme(theme)
        view.applyColors(colors)
    }
    /// The docked sidebar's springs, which DevTools open and close on too.
    func configureOpen() { slide.configure(response: 0.185, bounce: 0.2) }
    func configureCollapse() { slide.configure(response: 0.17, bounce: 0.15) }
}

@MainActor extension BrowserController {
    func installAIChat() {
        let panel = aiChat, view = panel.view
        root.addSubview(panel.shadow, positioned: .above, relativeTo: pageShadow)
        root.addSubview(panel.handle, positioned: .above, relativeTo: panel.shadow)
        if let width = preferences.object(forKey: AIChatStyle.widthKey) as? Double { panel.chosenWidth = CGFloat(width) }
        panel.applyTheme(theme)
        var start: CGFloat?
        panel.handle.onDrag = { [weak self] distance in
            guard let self else { return }
            let from = start ?? panel.shadow.frame.width; start = from
            panel.chosenWidth = max(AIChatStyle.minimumWidth, from-distance)
            self.layoutAIChatMotion()
        }
        panel.handle.onDragEnd = { [weak self] in
            start = nil
            panel.chosenWidth = panel.shadow.frame.width
            self?.preferences.set(Double(panel.shadow.frame.width), forKey: AIChatStyle.widthKey)
        }
        panel.handle.onReset = { [weak self] in
            panel.chosenWidth = nil
            self?.preferences.removeObject(forKey: AIChatStyle.widthKey)
            self?.layoutAIChatMotion()
        }
        view.onClose = { [weak self] in self?.closeAIChat() }
        view.onLeave = { [weak self] in
            guard let self, let page = self.selectedTab?.page.view else { return }
            self.window?.makeFirstResponder(page)
        }
        view.snapshot = { [weak self] page in
            guard let id = page.tabID, let tab = self?.tabs.first(where: { $0.id == id }) else { return nil }
            return try? await PageAssistant.snapshot(of: tab.page)
        }
        view.respond = { [weak self] messages in
            let provider = self?.modelChoice ?? .openRouter
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    do {
                        try await ModelService.run(messages, provider: provider) { event in
                            if case .text(let text) = event { continuation.yield(text) }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        view.openPages = { [weak self] in
            guard let self else { return [] }
            return self.tabs.compactMap(self.aiChatAttachment)
        }
        view.providerMenu = { [weak self] in self?.makeAIProviderMenu() ?? NSMenuItem() }
        view.modelName = { [weak self] in
            guard let choice = self?.modelChoice else { return "" }
            return choice.modelName+(choice.provider == .openCode ? " via OpenCode" : " via \(choice.provider.title)")
        }
    }
    /// A tab the chat can read: a web page or a file.
    func aiChatAttachment(_ tab: BrowserTab) -> AIChatAttachment? {
        guard let url = tab.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return AIChatAttachment(tabID: tab.id, title: tab.title, url: url, favicon: tab.favicon(for: theme))
    }
    /// The page in front is the one a new question is about, as in Dia.
    func refreshAIChatPage() {
        guard aiChat.isOpen else { return }
        aiChat.view.setCurrentPage(selectedTab.flatMap(aiChatAttachment))
    }

    /// ⌘E: opens the chat beside the page, with the page attached, or closes it.
    @objc func toggleAIChat() { if aiChat.isOpen { closeAIChat() } else { openAIChat() } }
    func openAIChat() {
        let panel = aiChat
        panel.applyTheme(theme)
        panel.view.setCurrentPage(selectedTab.flatMap(aiChatAttachment))
        panel.configureOpen(); panel.slide.target = 1
        animateAIChat()
        panel.view.composer.focus()
    }
    func closeAIChat() {
        let panel = aiChat
        guard panel.isOpen else { return }
        panel.configureCollapse(); panel.slide.target = 0
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: panel.view), let page = selectedTab?.page.view {
            window?.makeFirstResponder(page)
        }
        animateAIChat()
    }

    /// Places the chat at the right of `bounds`, and returns how much of the window it takes from the page.
    func layoutAIChat(in bounds: NSRect, pageLeft: CGFloat) -> CGFloat {
        let panel = aiChat, progress = panel.progress
        panel.shadow.isHidden = progress <= 0
        guard progress > 0 else { panel.handle.isHidden = true; return 0 }
        let inset = PageAppearance.inset, width = panel.width(room: bounds.width-pageLeft-inset)
        let room = width+inset
        let docked = NSRect(x: bounds.maxX-inset-width, y: bounds.minY+inset, width: width, height: max(0, bounds.height-2*inset))
        panel.shadow.frame = docked.offsetBy(dx: room*(1-progress), dy: 0)
        panel.shadow.refreshOutline()
        panel.clip.frame = panel.shadow.bounds
        panel.view.frame = panel.clip.bounds
        panel.handle.frame = NSRect(x: panel.shadow.frame.minX-inset, y: panel.shadow.frame.minY, width: inset, height: panel.shadow.frame.height)
        if panel.handle.isHidden { panel.handle.isHidden = false; panel.handle.refreshHover() }
        return max(0, room*progress)
    }

    private func animateAIChat() {
        let panel = aiChat
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.link?.invalidate(); panel.link = nil
            panel.slide.settle(); layoutAIChatMotion(); return
        }
        guard panel.link == nil else { return }
        panel.lastTick = CACurrentMediaTime()
        let link = root.displayLink(target: self, selector: #selector(tickAIChat(_:)))
        link.add(to: .main, forMode: .common); panel.link = link
        layoutAIChatMotion()
    }
    @objc private func tickAIChat(_ link: CADisplayLink) {
        let panel = aiChat
        let now = CACurrentMediaTime(), dt = min(0.05, now-(panel.lastTick ?? now)); panel.lastTick = now
        panel.slide.step(dt)
        if panel.slide.isResting(within: 0.001) {
            panel.slide.settle(); link.invalidate(); panel.link = nil
        }
        layoutAIChatMotion()
    }
    fileprivate func layoutAIChatMotion() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
}
