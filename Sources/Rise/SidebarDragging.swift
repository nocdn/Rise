import AppKit

@MainActor extension SidebarView {
    func canonicalID(for row: NSView) -> UUID? {
        (row as? TabRow)?.tabID ?? (row as? SplitTabRow)?.group.leftID
    }
    func displayedRow(for id: UUID) -> NSView? {
        displayedRows.first { ($0 as? TabRow)?.tabID == id || ($0 as? SplitTabRow)?.group.contains(id) == true }
    }
    func beginTabDrag(_ id: UUID, event: NSEvent) {
        guard drag == nil, let row = displayedRow(for: id), let canonical = canonicalID(for: row) else { return }
        finishReturningTab()
        // Continue from a row's visible position if it was still settling.
        if let layer = row.layer, let position = layer.presentation()?.position {
            var frame = row.frame; frame.origin.y = position.y-layer.anchorPoint.y*row.bounds.height
            TabListMotion.move(row, to: frame, animated: false)
        }
        row.layer?.removeAnimation(forKey: TabListMotion.movementKey)
        let point = rowsHost.convert(event.locationInWindow, from: nil)
        let drag = SidebarDrag(view: row, id: canonical, order: orderedIDs, startPoint: point, event: event)
        self.drag = drag
        let fraction = row.convert(row.bounds, to: self).midY / max(1, bounds.height)
        let fill = TabAppearance.dragFill(newTab.theme, sidebarFraction: fraction)
        (row as? TabRow)?.dragFill = fill
        (row as? SplitTabRow)?.dragFill = fill
        rowsHost.addSubview(row, positioned: .above, relativeTo: nil)
        liftDraggedTab(drag)
        if let shadow = drag.overlay?.shadowView { TabDragMotion.showShadow(shadow) }
        (window as? BrowserWindow)?.isDraggingTab = true
        dragScrollTimer = Timer(timeInterval: 1/60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollDraggedTab() }
        }
        RunLoop.main.add(dragScrollTimer!, forMode: .common)
    }
    func moveTabDrag(_ event: NSEvent) {
        guard let drag else { return }; drag.event = event
        let point = rowsHost.convert(event.locationInWindow, from: nil)
        let pull = point.x-drag.startPoint.x
        let maxY = max(0, targetFrames.values.map(\.minY).max() ?? 0)
        let desiredY = point.y-drag.grabOffset.y
        let slotY = min(max(0, desiredY), maxY)
        let verticalPull = desiredY-slotY
        let distance = max(max(0, pull), abs(verticalPull))
        var springs = false
        if drag.isDetached, distance <= TabDragMotion.captureDistance,
                  scroll.frame.contains(convert(event.locationInWindow, from: nil)) {
            drag.isDetached = false; springs = true
        }
        if drag.isDetached {
            placeDraggedTab(drag, frame: NSRect(x: point.x-drag.grabOffset.x, y: point.y-drag.grabOffset.y,
                                               width: drag.view.bounds.width, height: drag.view.bounds.height), spring: springs)
            positionSelectedTabShadow()
            return
        }
        var frame = NSRect(origin: .zero, size: drag.view.bounds.size)
        frame.origin.x = TabAppearance.inset + TabDragMotion.resistedOffset(pull)
        let minimum = max(0,scroll.contentView.bounds.minY)
        let maximum = max(minimum,min(maxY,scroll.contentView.bounds.maxY-frame.height))
        frame.origin.y = min(max(minimum, slotY),maximum)
        if verticalPull != 0 {
            frame.origin.y += (verticalPull < 0 ? -1 : 1) * TabDragMotion.resistedOffset(abs(verticalPull))
        }
        placeDraggedTab(drag, frame: frame, spring: springs)
        if let shadow = drag.overlay?.shadowView {
            TabDragMotion.updateShadow(shadow, progress: distance/TabDragMotion.releaseDistance, animated: springs)
        }
        guard var index = orderedIDs.firstIndex(of: drag.id) else { return }
        var crossed = false
        while index > 0, let neighbor = targetFrames[orderedIDs[index-1]], frame.minY <= neighbor.minY {
            orderedIDs.swapAt(index,index-1); displayedRows.swapAt(index,index-1); index -= 1
            layoutDragSlots(); crossingClick(); crossed = true
        }
        while index+1 < orderedIDs.count, let neighbor = targetFrames[orderedIDs[index+1]], frame.minY >= neighbor.minY {
            orderedIDs.swapAt(index,index+1); displayedRows.swapAt(index,index+1); index += 1
            layoutDragSlots(); crossingClick(); crossed = true
        }
        if crossed {
            onReorder?(orderedIDs)
            // Different row heights can change the last slot after crossing.
            // Keep the held row inside its new range without changing its size.
            if verticalPull == 0 {
                frame.origin.y = min(frame.minY, targetFrames.values.map(\.minY).max() ?? frame.minY)
                placeDraggedTab(drag, frame: frame)
            }
        }
        if distance >= TabDragMotion.releaseDistance, drag.overlay != nil {
            drag.isDetached = true; detachmentClick()
            placeDraggedTab(drag, frame: NSRect(x: point.x-drag.grabOffset.x, y: desiredY,
                                               width: frame.width, height: frame.height), spring: true)
        }
        positionSelectedTabShadow()
    }
    private func layoutDragSlots() { needsLayout = true; layoutSubtreeIfNeeded() }
    private func liftDraggedTab(_ drag: SidebarDrag) {
        guard drag.overlay == nil, let host = window?.contentView else { return }
        let overlay = TabDragOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onPointerMove = { [weak self] event in self?.refreshReturningTabHover(at: event.locationInWindow) }
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        var frame = drag.view.convert(drag.view.bounds, to: overlay)
        frame.size = drag.view.bounds.size
        overlay.shadowView.frame = frame
        overlay.addSubview(drag.view); drag.view.frame = frame
        drag.overlay = overlay
    }
    private func placeDraggedTab(_ drag: SidebarDrag, frame: NSRect, spring: Bool = false) {
        var target = drag.overlay.map { rowsHost.convert(frame, to: $0) } ?? frame
        target.size = frame.size
        if let shadow = drag.overlay?.shadowView { TabDragMotion.move(shadow, to: target, spring: spring) }
        TabDragMotion.move(drag.view, to: target, spring: spring)
    }
    func endTabDrag(at location: NSPoint? = nil, cancelled: Bool = false) {
        guard let drag else { return }
        self.drag = nil; dragScrollTimer?.invalidate(); dragScrollTimer = nil
        (window as? BrowserWindow)?.isDraggingTab = false
        if drag.overlay != nil { returningDrag = drag }
        if cancelled {
            let byID = Dictionary(uniqueKeysWithValues: displayedRows.compactMap { row in canonicalID(for: row).map { ($0,row) } })
            let order = drag.originalOrder.filter { byID[$0] != nil }
            orderedIDs = order + orderedIDs.filter { !order.contains($0) }
            displayedRows = orderedIDs.compactMap { byID[$0] }
            onReorder?(orderedIDs)
        }
        layoutDragSlots()
        if drag.overlay != nil, let target = targetFrames[drag.id], displayedRows.contains(where: { $0 === drag.view }) {
            placeDraggedTab(drag, frame: target, spring: true)
            clearDragFill(drag.view, at: location ?? drag.event.locationInWindow, animated: true)
            if let shadow = drag.overlay?.shadowView {
                let selected = selectedTabID.flatMap { displayedRow(for: $0) } === drag.view
                let visible = scroll.frame.contains(drag.view.convert(drag.view.bounds, to: self))
                TabDragMotion.returnShadow(shadow, matching: selected && visible ? selectedTabShadow : nil)
            }
            let work = DispatchWorkItem { [weak self, weak drag] in
                guard let self, let drag, self.returningDrag === drag else { return }
                self.finishReturningTab()
            }
            drag.returnWork = work
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : TabDragMotion.spring.settlingDuration
            DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
        } else {
            finishReturningTab()
            clearDragAppearance(drag.view)
        }
    }
    func finishReturningTab() {
        guard let drag = returningDrag else { return }
        returningDrag = nil; drag.returnWork?.cancel()
        drag.view.layer?.removeAnimation(forKey: TabDragMotion.springKey)
        if let target = targetFrames[drag.id], displayedRows.contains(where: { $0 === drag.view }) {
            rowsHost.addSubview(drag.view, positioned: .above, relativeTo: nil)
            TabListMotion.move(drag.view, to: target, animated: false)
        } else { drag.view.removeFromSuperview() }
        drag.overlay?.removeFromSuperview()
        clearDragAppearance(drag.view)
        if let row = drag.view as? TabRow { row.refreshHover() }
        if let pair = drag.view as? SplitTabRow { pair.left.refreshHover(); pair.right.refreshHover() }
        positionSelectedTabShadow()
    }
    private func clearDragAppearance(_ view: NSView) {
        clearDragFill(view)
    }
    private func clearDragFill(_ view: NSView, at location: NSPoint? = nil, animated: Bool = false) {
        TabDragMotion.fadeBackground(view, animated: animated) {
            if let row = view as? TabRow {
                row.dragFill = nil; row.refreshHover(at: location)
            }
            (view as? SplitTabRow)?.dragFill = nil
        }
        if let pair = view as? SplitTabRow {
            clearDragFill(pair.left, at: location, animated: animated)
            clearDragFill(pair.right, at: location, animated: animated)
        }
    }
    func refreshReturningTabHover(at location: NSPoint) {
        guard let view = returningDrag?.view else { return }
        (view as? TabRow)?.refreshHover(at: location)
        if let pair = view as? SplitTabRow { pair.left.refreshHover(at: location); pair.right.refreshHover(at: location) }
    }
    func cancelTabInteractions() {
        endTabDrag(cancelled: true)
        finishReturningTab()
        rows.values.forEach { $0.cancelPress(); $0.refreshHover(); $0.finishRename(save: false) }
    }
    private func autoscrollDraggedTab() {
        guard let drag else { dragScrollTimer?.invalidate(); dragScrollTimer = nil; return }
        guard !drag.isDetached else { return }
        let point = convert(drag.event.locationInWindow, from: nil)
        let y = point.y-scroll.frame.minY, height = scroll.bounds.height
        let delta: CGFloat = y < 24 ? -min(8,(24-y)/3) : y > height-24 ? min(8,(y-height+24)/3) : 0
        guard delta != 0 else { return }
        let clip = scroll.contentView
        let next = min(max(0,clip.bounds.minY+delta), max(0,rowsHost.bounds.height-clip.bounds.height))
        guard next != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: 0, y: next)); scroll.reflectScrolledClipView(clip)
        moveTabDrag(drag.event)
    }
}
