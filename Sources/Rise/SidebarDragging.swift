import AppKit

@MainActor extension SidebarView {
    func canonicalID(for row: NSView) -> UUID? {
        (row as? TabRow)?.tabID ?? (row as? SplitTabRow)?.group.leftID
    }
    func displayedRow(for id: UUID) -> NSView? {
        displayedRows.first { ($0 as? TabRow)?.tabID == id || ($0 as? SplitTabRow)?.group.contains(id) == true }
    }
    func pressTab(_ id: UUID, down: Bool, animated: Bool) {
        guard let row = displayedRow(for: id) else { return }
        if down {
            if let pressedRow, pressedRow !== row { TabListMotion.press(pressedRow, down: false, animated: false) }
            pressedRow = row
        } else if pressedRow === row { pressedRow = nil }
        TabListMotion.press(row, down: down, animated: animated)
        if selectedTabID.flatMap({ displayedRow(for: $0) }) === row { TabListMotion.press(selectedTabShadow, down: down, animated: animated) }
    }
    func beginTabDrag(_ id: UUID, event: NSEvent) {
        guard drag == nil, let row = displayedRow(for: id), let canonical = canonicalID(for: row) else { return }
        // Continue from a row's visible position if it was still settling.
        if let layer = row.layer, let position = layer.presentation()?.position {
            var frame = row.frame; frame.origin.y = position.y-layer.anchorPoint.y*row.bounds.height
            TabListMotion.move(row, to: frame, animated: false, at: CACurrentMediaTime())
        }
        row.layer?.removeAnimation(forKey: TabListMotion.movementKey)
        let point = rowsHost.convert(event.locationInWindow, from: nil)
        drag = SidebarDrag(view: row, id: canonical, order: orderedIDs, grabOffset: point.y-row.frame.minY, event: event)
        rowsHost.addSubview(row, positioned: .above, relativeTo: nil)
        dragScrollTimer = Timer(timeInterval: 1/60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollDraggedTab() }
        }
        RunLoop.main.add(dragScrollTimer!, forMode: .common)
    }
    func moveTabDrag(_ event: NSEvent) {
        guard let drag else { return }; drag.event = event
        let point = rowsHost.convert(event.locationInWindow, from: nil)
        let maxY = max(8, targetFrames.values.map(\.minY).max() ?? 8)
        var frame = drag.view.frame
        frame.origin.x = 8
        let minimum = max(8,scroll.contentView.bounds.minY)
        let maximum = max(minimum,min(maxY,scroll.contentView.bounds.maxY-frame.height))
        frame.origin.y = min(max(minimum, point.y-drag.grabOffset),maximum)
        TabListMotion.move(drag.view, to: frame, animated: false, at: CACurrentMediaTime())
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
            frame.origin.y = min(frame.minY, targetFrames.values.map(\.minY).max() ?? frame.minY)
            TabListMotion.move(drag.view, to: frame, animated: false, at: CACurrentMediaTime())
        }
        positionSelectedTabShadow()
    }
    private func layoutDragSlots() { needsLayout = true; layoutSubtreeIfNeeded() }
    func endTabDrag(cancelled: Bool = false) {
        guard let drag else { return }
        self.drag = nil; dragScrollTimer?.invalidate(); dragScrollTimer = nil
        if cancelled {
            let byID = Dictionary(uniqueKeysWithValues: displayedRows.compactMap { row in canonicalID(for: row).map { ($0,row) } })
            let order = drag.originalOrder.filter { byID[$0] != nil }
            orderedIDs = order + orderedIDs.filter { !order.contains($0) }
            displayedRows = orderedIDs.compactMap { byID[$0] }
            onReorder?(orderedIDs)
        }
        layoutDragSlots()
    }
    func cancelTabInteractions() {
        endTabDrag(cancelled: true)
        rows.values.forEach { $0.cancelPress(); $0.finishRename(save: false) }
    }
    private func autoscrollDraggedTab() {
        guard let drag else { dragScrollTimer?.invalidate(); dragScrollTimer = nil; return }
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
