#if DEBUG
import UIKit
import WebKit

/// Deterministic, isolated checks of the real deck, its gestures, and render-server paths.
@MainActor enum TabDeckAudit {
    static let argument = "-RiseTabDeckAudit"
    struct Failure: Error { let name: String }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("TabDeckAudit")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(name: name) }
        }
        @MainActor func pause(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        @MainActor func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        browser.overrideUserInterfaceStyle = .light
        browser.view.layoutIfNeeded()
        let control = TabCell(frame: CGRect(x: 0, y: 0, width: 280, height: 600))
        let touch = AuditTouch()
        var activations = 0
        control.onSelect = { activations += 1 }
        touch.point = CGPoint(x: 100, y: 100)
        _ = control.beginTracking(touch, with: nil)
        touch.point.x += 3
        _ = control.continueTracking(touch, with: nil)
        control.endTracking(touch, with: nil)
        try check("stationary-card-tap-with-small-finger-drift-activates-once", activations == 1)
        for direction: CGFloat in [-1, 1] {
            touch.point = CGPoint(x: 100, y: 100)
            _ = control.beginTracking(touch, with: nil)
            touch.point.x += direction*100
            let tracking = control.continueTracking(touch, with: nil)
            touch.point = CGPoint(x: 100, y: 100)
            control.endTracking(touch, with: nil)
            try check("sideways-drag-\(Int(direction))-never-activates-even-if-it-returns-to-origin", !tracking && activations == 1)
        }
        touch.point = CGPoint(x: 100, y: 100)
        _ = control.beginTracking(touch, with: nil)
        touch.point.x += 100
        control.endTracking(touch, with: nil)
        try check("coalesced-fast-drag-cannot-be-treated-as-a-tap", activations == 1)
        touch.point = CGPoint(x: 100, y: 100)
        _ = control.beginTracking(touch, with: nil)
        control.cancelTracking(with: nil)
        control.endTracking(touch, with: nil)
        try check("scroll-cancellation-cannot-open-a-tab", activations == 1)
        let size = browser.view.bounds.size
        let colors: [UIColor] = [.systemOrange, .systemTeal, .systemIndigo, .systemPink]
        for (index, tab) in browser.tabs.enumerated() {
            tab.snapshot = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(white: 0.98, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                colors[index%colors.count].setFill(); context.fill(CGRect(x: 0, y: 0, width: size.width, height: 180))
                ("Page \(index+1)" as NSString).draw(at: CGPoint(x: 24, y: 90), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white,
                ])
                for row in 0..<12 {
                    UIColor(white: 0.85, alpha: 1).setFill()
                    context.fill(CGRect(x: 24, y: 220+CGFloat(row)*42, width: size.width-60-CGFloat(row%3)*20, height: 12))
                }
            }
        }
        browser.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body{margin:0;background:#f8f8fb;font:18px system-ui}header{background:#5856d6;color:white;padding:70px 24px 30px}p{margin:25px}</style><header><h1>Rise tab deck</h1></header><p>A live page follows the same path as every saved preview.</p>",
                                      baseURL: URL(string: "https://deck.rise.test/"))
        for _ in 0..<150 where browser.webView.isLoading { try await pause(20) }
        try await pause(700)
        let switcher = browser.tabSwitcher
        let identities = browser.tabs.map(\.id)
        var committed = false
        var bitmapAfterCommit = false
        var onset = 0.0
        let action = CACurrentMediaTime()
        switcher.onFlightCommit = { committed = true; onset = (CACurrentMediaTime()-action)*1000 }
        let drawBitmap = switcher.onFlight
        switcher.onFlight = { bitmapAfterCommit = committed; drawBitmap() }
        browser.showTabSwitcher()
        try check("takeoff-commits-before-the-deferred-page-bitmap", committed && bitmapAfterCommit)
        try check("deck-order-keeps-the-active-tab-at-the-right", switcher.displayOrder.last == browser.tabIndex)
        try check("opening-does-not-reorder-the-shared-session", browser.tabs.map(\.id) == identities)
        let active = try require(switcher.moving, "moving page")
        try check("moving-page-keeps-the-horizontal-scroll-gesture-in-its-ancestry", active.isDescendant(of: switcher.scroll))
        try check("card-close-gesture-does-not-veto-the-deck-pan", switcher.cells.allSatisfy {
            $0.gestureRecognizerShouldBegin(switcher.scroll.panGestureRecognizer)
        })
        let corners = (active.layer.animation(forKey: "flight.cornerRadius") as? CAKeyframeAnimation)?.values?
            .compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        try JSONSerialization.data(withJSONObject: ["first": corners.first ?? -1, "last": corners.last ?? -1,
                                                    "model": active.layer.cornerRadius])
            .write(to: folder.appendingPathComponent("initial-corners.json"))
        try check("page-is-device-rounded-in-the-first-animation-frame", (corners.first ?? 0) >= 28.7)
        let buttonDuration = active.layer.animation(forKey: "flight.bounds")?.duration ?? 0
        try check("button-flight-has-arcs-short-duration", (0.25...0.65).contains(buttonDuration))
        let others = switcher.cells.enumerated().filter { $0.offset != switcher.current && !$0.element.isHidden }.map(\.element)
        try check("other-tabs-start-the-stack-rise-immediately", !others.isEmpty && others.allSatisfy {
            $0.layer.animation(forKey: "deck.position") != nil && $0.layer.animation(forKey: "deck.transform") != nil
        })
        func approaches(_ values: [CGFloat], target: CGFloat, landsExactly: Bool = false) -> Bool {
            guard let first = values.first, let last = values.last else { return false }
            let direction: CGFloat = target >= first ? 1 : -1
            return values.allSatisfy { ($0-first)*direction >= -0.001 && (target-$0)*direction >= -0.001 }
                && zip(values, values.dropFirst()).allSatisfy { ($1-$0)*direction >= -0.001 }
                && (!landsExactly || abs(last-target) < 0.001)
        }
        try check("rising-tabs-fly-straight-to-their-positions-without-bouncing", others.allSatisfy { cell in
            let positions = (cell.layer.animation(forKey: "deck.position") as? CAKeyframeAnimation)?.values?
                .compactMap { ($0 as? NSValue)?.cgPointValue } ?? []
            return approaches(positions.map(\.x), target: cell.center.x, landsExactly: true)
                && approaches(positions.map(\.y), target: cell.center.y, landsExactly: true)
        })
        try check("rising-tabs-grow-without-overshooting-their-resting-size", others.allSatisfy { cell in
            let transforms = (cell.layer.animation(forKey: "deck.transform") as? CAKeyframeAnimation)?.values?
                .compactMap { ($0 as? NSValue)?.caTransform3DValue } ?? []
            return approaches(transforms.map(\.m11), target: 1, landsExactly: true)
                && approaches(transforms.map(\.m22), target: 1, landsExactly: true)
        })
        let pagePositions = (active.layer.animation(forKey: "flight.position") as? CAKeyframeAnimation)?.values?
            .compactMap { ($0 as? NSValue)?.cgPointValue } ?? []
        let pageBounds = (active.layer.animation(forKey: "flight.bounds") as? CAKeyframeAnimation)?.values?
            .compactMap { ($0 as? NSValue)?.cgRectValue } ?? []
        try check("active-page-button-entry-also-has-no-bounce", approaches(pagePositions.map(\.x), target: active.center.x)
                  && approaches(pagePositions.map(\.y), target: active.center.y)
                  && approaches(pageBounds.map(\.width), target: active.bounds.width))
        try check("every-rising-tab-is-rounded-from-its-first-frame", others.allSatisfy {
            let values = ($0.card.layer.animation(forKey: "deck.cornerRadius") as? CAKeyframeAnimation)?.values?
                .compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            return (values.first ?? 0) >= 28.7
        })
        try check("both-page-and-stack-keyframes-request-promotion", active.layer.animation(forKey: "flight.bounds")?.preferredFrameRateRange.preferred == 120
                  && others.allSatisfy { $0.layer.animation(forKey: "deck.position")?.preferredFrameRateRange.preferred == 120 })
        var frames: [[String: Double]] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime()-start < 0.65 {
            if let shown = switcher.moving?.layer.presentation() {
                frames.append(["t": CACurrentMediaTime()-start, "x": shown.frame.minX, "y": shown.frame.minY,
                               "width": shown.bounds.width, "height": shown.bounds.height, "radius": shown.cornerRadius])
            }
            try await pause(8)
        }
        try JSONSerialization.data(withJSONObject: ["onsetMilliseconds": onset, "buttonDuration": buttonDuration, "frames": frames], options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("motion.json"))
        switcher.onFlightCommit = {}; switcher.onFlight = drawBitmap
        try check("current-page-lands-without-a-shadow-or-replica-remnant", switcher.moving == nil && switcher.movingShadow == nil)
        try check("large-cards-match-the-reference-width", abs(switcher.cardSize.width/size.width-0.70) < 0.002)
        let front = switcher.cells[switcher.focusedIndex!]
        try check("only-the-centred-tab-shows-its-title", switcher.cells.enumerated().allSatisfy {
            $0.element.title.alpha == ($0.offset == switcher.focusedIndex ? 1 : 0)
        })
        try check("titles-and-favicons-are-above-the-cards", front.caption.frame.maxY < front.card.frame.minY
                  && abs(front.title.frame.midY-front.favicon.frame.midY) < 1)
        try check("caption-leading-edge-is-inset-from-its-page", abs(front.caption.frame.minX-front.card.frame.minX-TabCell.captionOffset) < 0.1
                  && front.favicon.frame.minX == 0 && front.title.frame.minX == front.favicon.frame.maxX+6)
        try check("active-page-remains-visible-at-the-right-edge", switcher.cellFrame(switcher.current).minX > size.width*0.65
                  && switcher.cellFrame(switcher.current).minX < size.width)
        try check("card-shadow-is-present-at-landing", front.cardShadow.layer.shadowOpacity == 0.10 && front.cardShadow.layer.shadowPath != nil)
        try check("close-buttons-remain-explicit-accessibility-targets", switcher.cells.allSatisfy { $0.closeButton.isAccessibilityElement })
        try screenshot("deck-entry")

        for index in browser.tabs.indices {
            switcher.focusTab(index, animated: true)
            try await pause(450)
            let frame = switcher.cells[index].card.convert(switcher.cells[index].card.bounds, to: switcher)
            try check("horizontal-navigation-brings-tab-\(index)-forward", switcher.focusedIndex == index
                      && frame.minX >= 0 && frame.maxX <= size.width && !switcher.cells[index].isHidden)
            try check("horizontal-navigation-shows-only-title-\(index)", switcher.cells.enumerated().allSatisfy {
                $0.element.title.alpha == ($0.offset == index ? 1 : 0)
            })
        }
        try screenshot("deck-last")
        let lastFocused = switcher.focusedIndex
        let previous = switcher.accessibilityScroll(.right)
        try await pause(400)
        try check("voiceover-can-move-back-through-the-horizontal-deck", previous && switcher.focusedIndex != lastFocused)
        let next = switcher.accessibilityScroll(.left)
        try await pause(400)
        try check("voiceover-can-move-forward-through-the-horizontal-deck", next && switcher.focusedIndex == lastFocused)
        for (name, viewport) in [("small-phone", CGSize(width: 320, height: 568)),
                                 ("landscape", CGSize(width: 852, height: 393)),
                                 ("tablet", CGSize(width: 1024, height: 1366))] {
            let layout = TabDeckLayout(size: viewport, stripHeight: 54, topInset: 54, bottomInset: 90, count: 4, focus: 2)
            let frame = layout.frame(at: 2)
            try check("\(name)-keeps-the-page-clear-of-both-bars", frame.minY >= 54
                      && frame.maxY <= viewport.height-90+0.5 && frame.width > 0 && frame.height > 0)
            try check("\(name)-only-left-cards-scale-down", abs(layout.frame(at: 1).width/frame.width-0.980) < 0.001
                      && layout.frame(at: 3).width == frame.width)
            let body = frame.inset(by: UIEdgeInsets(top: TabSwitcherView.titleHeight, left: 0, bottom: 0, right: 0))
            let side = layout.frame(at: 1).inset(by: UIEdgeInsets(top: TabSwitcherView.titleHeight, left: 0, bottom: 0, right: 0))
            try check("\(name)-shrinks-equally-at-the-top-and-bottom", abs(body.midY-side.midY) < 0.001
                      && side.minY > body.minY && side.maxY < body.maxY)
        }
        let between = TabDeckLayout(size: size, stripHeight: 54, topInset: 54, bottomInset: 90, count: 4, focus: 1.6)
        try check("fractional-swiping-never-overlaps-title-text", (0..<4).filter { between.titleOpacity(at: $0) > 0 }.count == 1
                  && between.titleOpacity(at: 2) > 0 && between.titleOpacity(at: 2) < 1)
        try check("rightmost-card-stays-at-peak-size-through-the-whole-swipe", [CGFloat(0), 0.5, 1.6, 2.8, 3].allSatisfy {
            let layout = TabDeckLayout(size: size, stripHeight: 54, topInset: 54, bottomInset: 90, count: 4, focus: $0)
            return layout.frame(at: 3).width == layout.cardSize.width
                && layout.frame(at: 3).height-TabSwitcherView.titleHeight == layout.cardSize.height
        })
        try check("left-stack-darkens-progressively-while-centre-and-right-stay-clear",
                  between.shadeOpacity(at: 0) > between.shadeOpacity(at: 1)
                  && between.shadeOpacity(at: 1) > 0
                  && between.shadeOpacity(at: 2) == 0 && between.shadeOpacity(at: 3) == 0)
        var projected = CGPoint(x: 100_000, y: 10)
        withUnsafeMutablePointer(to: &projected) {
            switcher.scrollViewWillEndDragging(switcher.scroll, withVelocity: CGPoint(x: 4, y: 0), targetContentOffset: $0)
        }
        try check("fast-horizontal-flick-snaps-within-the-last-tab", abs(projected.x-switcher.scroll.contentSize.width+size.width) < 0.5 && projected.y == 0)
        projected = CGPoint(x: -500, y: 2)
        withUnsafeMutablePointer(to: &projected) {
            switcher.scrollViewWillEndDragging(switcher.scroll, withVelocity: CGPoint(x: -4, y: 0), targetContentOffset: $0)
        }
        try check("leading-rubber-band-snaps-back-to-the-first-tab", projected == .zero)

        switcher.focusTab(1)
        browser.selectTab(1)
        try await pause(70)
        let growing = try require(switcher.moving, "growing page")
        let before = growing.layer.presentation()?.frame ?? growing.frame
        browser.showTabSwitcher()
        let first = (growing.layer.animation(forKey: "flight.bounds") as? CAKeyframeAnimation)?.values?.first as? NSValue
        try check("rapid-toggle-reuses-the-same-rounded-page", switcher.moving === growing
                  && abs((first?.cgRectValue.width ?? 0)-before.width) < 8)
        try await pause(650)
        browser.selectTab(browser.tabIndex)
        try await pause(550)
        browser.showTabSwitcher()
        try await pause(70)
        switcher.scrollViewWillBeginDragging(switcher.scroll)
        let held = try require(switcher.moving, "caught page")
        let heldX = held.center.x
        switcher.scroll.contentOffset.x += 30
        try check("horizontal-swipe-catches-an-entering-page-continuously", held === switcher.moving
                  && abs(held.center.x-heldX) < size.width*0.3)
        switcher.scrollViewDidEndDragging(switcher.scroll, willDecelerate: false)
        try await pause(650)
        try check("caught-entrance-settles-cleanly", switcher.moving == nil && switcher.movingShadow == nil)

        browser.selectTab(browser.tabIndex)
        try await pause(550)
        browser.beginTabSwipe()
        browser.updateTabSwipe(CGPoint(x: 0, y: -4))
        try check("swipe-rounds-the-page-at-its-first-movement", (switcher.moving?.layer.cornerRadius ?? 0) > 28)
        browser.updateTabSwipe(CGPoint(x: 0, y: -45))
        browser.endTabSwipe(velocity: .zero, cancelled: true)
        try await pause(550)
        try check("cancelled-bottom-swipe-restores-the-live-page", switcher.isHidden && !browser.isTabSwitcherOpen)
        browser.beginTabSwipe()
        browser.updateTabSwipe(CGPoint(x: -10, y: -150))
        try await pause(20)
        let visibleWidth = switcher.moving?.layer.presentation()?.bounds.width ?? 0
        browser.updateTabSwipe(CGPoint(x: -14, y: -180))
        browser.endTabSwipe(velocity: CGPoint(x: -200, y: -2200))
        let release = (switcher.moving?.layer.animation(forKey: "flight.bounds") as? CAKeyframeAnimation)?.values?.first as? NSValue
        try check("strong-flick-starts-from-the-last-displayed-size", abs((release?.cgRectValue.width ?? 0)-visibleWidth) < 2)
        try await pause(700)
        try check("committed-bottom-swipe-lands-in-the-horizontal-deck", browser.isTabSwitcherOpen && switcher.moving == nil && switcher.grid.alpha == 1)

        let middle = switcher.displayOrder[1], behind = switcher.displayOrder[0]
        switcher.focusTab(middle)
        try await pause(40)
        let closing = switcher.cells[middle], count = browser.tabs.count, id = browser.tabs[middle].id
        let neighbour = switcher.cells[behind], neighbourID = browser.tabs[behind].id
        let resting = neighbour.frame, restingShade = neighbour.shadeAmount
        closing.beginCloseDrag(); closing.updateCloseDrag(-40)
        try check("dragging-a-tab-up-keeps-it-fully-opaque", closing.alpha == 1)
        let smallDrag = neighbour.frame
        try check("the-tab-behind-moves-right-during-the-first-part-of-the-drag", smallDrag.midX > resting.midX+4)
        closing.updateCloseDrag(-120)
        try check("dragging-further-brings-the-tab-behind-further-forward",
                  neighbour.frame.midX > smallDrag.midX+4 && neighbour.frame.width > smallDrag.width
                  && neighbour.shadeAmount < restingShade)
        try check("interactive-close-still-shows-only-one-title", switcher.cells.filter { $0.title.alpha > 0.001 }.count <= 1)
        closing.updateCloseDrag(-40)
        try check("reversing-the-finger-reverses-the-neighbours-progress", abs(neighbour.frame.midX-smallDrag.midX) < 0.1)
        closing.endCloseDrag(-40, velocity: 0, cancelled: true)
        try await pause(80)
        let beforeCatch = neighbour.shownCardFrame(in: switcher)
        closing.beginCloseDrag()
        let afterCatch = neighbour.shownCardFrame(in: switcher)
        try check("a-new-close-drag-catches-the-cancellation-without-a-jump",
                  hypot(afterCatch.midX-beforeCatch.midX, afterCatch.midY-beforeCatch.midY) < 5)
        closing.updateCloseDrag(-20)
        closing.endCloseDrag(-20, velocity: 0, cancelled: true)
        try await pause(450)
        try check("cancelled-close-drag-keeps-the-tab", browser.tabs.count == count && closing.transform == .identity && closing.alpha == 1)
        try check("cancelling-restores-the-neighbours-position-size-and-shade", abs(neighbour.frame.midX-resting.midX) < 0.1
                  && abs(neighbour.frame.width-resting.width) < 0.1 && abs(neighbour.shadeAmount-restingShade) < 0.001)
        let closeAction = switcher.onClose
        var reflowBefore = CGRect.zero, reflowFirst = CGRect.zero
        var animationContinues = false
        switcher.onClose = { index in
            reflowBefore = neighbour.shownCardFrame(in: switcher)
            let animation = neighbour.layer.animation(forKey: "position")
            closeAction(index)
            reflowFirst = neighbour.shownCardFrame(in: switcher)
            let after = neighbour.layer.animation(forKey: "position")
            animationContinues = animation != nil && animation?.beginTime == after?.beginTime && animation?.duration == after?.duration
        }
        closing.beginCloseDrag()
        // Record a slow, visible drag as well as the release; the audit must not only
        // check the final layout after deleting a tab.
        for step in 1...18 {
            closing.updateCloseDrag(-CGFloat(step)*8)
            try await pause(16)
        }
        let releasePosition = (neighbour.layer.presentation() ?? neighbour.layer).position
        closing.endCloseDrag(-144, velocity: -900, cancelled: false)
        let releaseSpring = neighbour.layer.animation(forKey: "position") as? CABasicAnimation
        var releaseFrom = (releaseSpring?.fromValue as? NSValue)?.cgPointValue ?? .zero
        if releaseSpring?.isAdditive == true {
            releaseFrom.x += neighbour.layer.position.x
            releaseFrom.y += neighbour.layer.position.y
        }
        try check("release-eases-from-the-neighbours-current-drag-position", releaseSpring != nil
                  && hypot(releaseFrom.x-releasePosition.x, releaseFrom.y-releasePosition.y) < 1)
        var opaque = true
        var releaseFrames: [[String: Double]] = []
        let releaseTime = CACurrentMediaTime()
        for _ in 0..<55 {
            if closing.superview != nil { opaque = opaque && (closing.layer.presentation()?.opacity ?? closing.layer.opacity) >= 0.999 }
            let frame = neighbour.shownCardFrame(in: switcher)
            releaseFrames.append(["t": CACurrentMediaTime()-releaseTime, "x": frame.midX, "width": frame.width])
            try await pause(8)
        }
        switcher.onClose = closeAction
        try check("a-dismissed-tab-stays-opaque-through-its-entire-flight", opaque)
        try check("dismissed-tab-is-removed-offscreen-without-flying-back-in", closing.superview == nil)
        try JSONSerialization.data(withJSONObject: ["before": String(describing: reflowBefore),
            "first": String(describing: reflowFirst), "springContinues": animationContinues,
            "releaseFrames": releaseFrames], options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("close-reflow.json"))
        try check("removing-the-offscreen-card-does-not-restart-the-release-easing", animationContinues)
        try check("neighbour-keeps-moving-continuously-when-the-tab-is-removed", !reflowBefore.isEmpty
                  && hypot(reflowFirst.midX-reflowBefore.midX, reflowFirst.midY-reflowBefore.midY) < size.width*0.15)
        try check("swiping-a-card-up-closes-its-actual-tab", browser.tabs.count == count-1 && !browser.tabs.contains { $0.id == id })
        try check("closing-a-card-keeps-order-and-focus-valid", switcher.displayOrder.count == browser.tabs.count
                  && Set(switcher.displayOrder) == Set(browser.tabs.indices) && switcher.focusedIndex != nil)
        try check("the-tab-behind-becomes-focused-after-the-close", switcher.focusedIndex.map { browser.tabs[$0].id } == neighbourID)
        let firstIndex = switcher.displayOrder.first!, followingIndex = switcher.displayOrder[1]
        switcher.focusTab(firstIndex)
        try await pause(40)
        let firstCell = switcher.cells[firstIndex], followingCell = switcher.cells[followingIndex]
        let followingRest = followingCell.frame
        firstCell.beginCloseDrag(); firstCell.updateCloseDrag(-100)
        try check("closing-the-first-card-pulls-its-successor-left", followingCell.frame.midX < followingRest.midX-4)
        firstCell.endCloseDrag(-100, velocity: 0, cancelled: true)
        try await pause(80)
        let beforeScrollCatch = followingCell.shownCardFrame(in: switcher)
        switcher.scrollViewWillBeginDragging(switcher.scroll)
        let afterScrollCatch = followingCell.shownCardFrame(in: switcher)
        try check("horizontal-scrolling-can-catch-a-close-reflow-without-a-jump",
                  abs(afterScrollCatch.midX-beforeScrollCatch.midX) < 5 && abs(afterScrollCatch.width-beforeScrollCatch.width) < 1)
        switcher.scroll.contentOffset.x += 30
        switcher.scrollViewDidEndDragging(switcher.scroll, willDecelerate: false)
        try await pause(450)
        try check("caught-close-reflow-restores-the-cards-normal-transforms", switcher.cells.allSatisfy { $0.transform == .identity })
        let last = switcher.displayOrder.last!, preceding = switcher.displayOrder.dropLast().last!
        switcher.focusTab(last)
        // Let the nonanimated focus reach the presentation tree before measuring
        // the next action's starting frame, as it would between two real gestures.
        try await pause(40)
        let edgeNeighbour = switcher.cells[preceding]
        let edgeBefore = edgeNeighbour.shownCardFrame(in: switcher)
        switcher.cells[last].onClose()
        let edgeFirst = edgeNeighbour.shownCardFrame(in: switcher)
        try JSONSerialization.data(withJSONObject: ["before": String(describing: edgeBefore),
            "after": String(describing: edgeFirst), "position": String(describing: edgeNeighbour.layer.position),
            "animationKeys": edgeNeighbour.layer.animationKeys() ?? []], options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("edge-close.json"))
        try check("closing-the-last-slot-does-not-jump-when-the-scroll-range-shrinks",
                  hypot(edgeFirst.midX-edgeBefore.midX, edgeFirst.midY-edgeBefore.midY) < size.width*0.15
                  && (edgeNeighbour.layer.animationKeys() ?? []).contains { $0.hasPrefix("position") })
        try await pause(400)
        try check("the-remaining-tabs-settle-into-the-shorter-deck", switcher.focusedIndex == switcher.displayOrder.last
                  && abs(switcher.scroll.contentOffset.x-(switcher.scroll.contentSize.width-size.width)) < 0.5)
        try screenshot("after-close")
        browser.overrideUserInterfaceStyle = .dark
        try await pause(250)
        try screenshot("deck-dark")
        try check("dark-mode-keeps-the-same-card-geometry", abs(switcher.cardSize.width/size.width-0.70) < 0.002)
        browser.selectTab(browser.tabIndex)
        try await pause(550)
        browser.showTabSwitcher()
        try await pause(100)
        let enteringNeighbour = switcher.cells.first { $0 !== switcher.cells[switcher.current] }!
        let enteringFrame = enteringNeighbour.shownCardFrame(in: switcher)
        switcher.cells[switcher.current].onClose()
        let caughtFrame = enteringNeighbour.shownCardFrame(in: switcher)
        try check("closing-during-entry-preserves-the-neighbours-visible-pose",
                  hypot(caughtFrame.midX-enteringFrame.midX, caughtFrame.midY-enteringFrame.midY) < size.width*0.15
                  && enteringNeighbour.layer.animation(forKey: "transform") != nil)
        try await pause(400)
        try check("closing-during-entry-restores-the-survivors-full-size-and-corners",
                  enteringNeighbour.transform == .identity
                  && abs(enteringNeighbour.card.layer.cornerRadius-TabSwitcherView.cornerRadius) < 0.1
                  && abs(enteringNeighbour.card.bounds.width-switcher.cardSize.width) < 0.1)
        while browser.tabs.count > 1 {
            switcher.cells.last!.onClose()
            try await pause(400)
        }
        switcher.focusTab(0)
        try check("single-tab-is-centred-and-cannot-be-swiped-away", abs(switcher.cells[0].frame.midX-size.width/2) < 1
                  && switcher.cells[0].closeButton.isHidden)
        browser.selectTab(0)
        try await pause(550)
        try check("last-tab-opens-with-no-flight-remnants", switcher.isHidden && switcher.moving == nil && switcher.movingShadow == nil)
    }

    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw Failure(name: name) }
        return value
    }

    /// Drives the control's real tracking path without fabricating private HID events.
    private final class AuditTouch: UITouch {
        var point = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { point }
    }
}
#endif
