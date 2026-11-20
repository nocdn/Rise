import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Rise

final class FloatingVideoControlsTests: XCTestCase {
    @MainActor func testTemporarySystemSpaceShortcutUsesNativeHotkeyEventsAndReleasesCleanly() throws {
        _ = NSApplication.shared
        var available = true, toggles = 0
        let shortcut = FloatingVideoSpaceShortcut(available: { available }, action: { toggles += 1 })
        defer { shortcut.setEnabled(false) }
        shortcut.setEnabled(true)
        XCTAssertTrue(shortcut.isRegistered, "Unmodified Space is registered system-wide")
        func send(_ kind: UInt32) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, EventAttributes(kEventAttributeNone), &event), noErr)
            let ref = try XCTUnwrap(event); defer { ReleaseEvent(ref) }
            var id = FloatingVideoSpaceShortcut.identifier
            XCTAssertEqual(SetEventParameter(ref, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
            _ = SendEventToEventTarget(ref, GetApplicationEventTarget())
        }
        try send(UInt32(kEventHotKeyPressed)); try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(toggles, 1, "A held key toggles only once")
        try send(UInt32(kEventHotKeyReleased)); try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(toggles, 2)
        try send(UInt32(kEventHotKeyReleased)); available = false
        try send(UInt32(kEventHotKeyPressed)); XCTAssertEqual(toggles, 2)
        shortcut.setEnabled(false); XCTAssertFalse(shortcut.isRegistered)
        available = true; try send(UInt32(kEventHotKeyPressed)); XCTAssertEqual(toggles, 2)

        // F's shortcut takes only its own presses, beside Space's.
        var returns = 0
        let space = FloatingVideoSpaceShortcut(available: { true }, action: { toggles += 1 })
        let f = FloatingVideoSpaceShortcut(keyCode: kVK_ANSI_F, identifier: FloatingVideoSpaceShortcut.returnIdentifier, available: { true }, action: { returns += 1 })
        defer { space.setEnabled(false); f.setEnabled(false) }
        space.setEnabled(true); f.setEnabled(true)
        XCTAssertTrue(f.isRegistered)
        func press(_ identifier: EventHotKeyID) throws {
            for kind in [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)] {
                var event: EventRef?
                XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, EventAttributes(kEventAttributeNone), &event), noErr)
                let ref = try XCTUnwrap(event); defer { ReleaseEvent(ref) }
                var id = identifier
                XCTAssertEqual(SetEventParameter(ref, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
                _ = SendEventToEventTarget(ref, GetApplicationEventTarget())
            }
        }
        try press(FloatingVideoSpaceShortcut.returnIdentifier)
        XCTAssertEqual(returns, 1); XCTAssertEqual(toggles, 2)
        try press(FloatingVideoSpaceShortcut.identifier)
        XCTAssertEqual(returns, 1); XCTAssertEqual(toggles, 3)
    }

    @MainActor func testSpaceCoversTheWholePictureAndCornerButtonsSitNearerTheEdges() throws {
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main))
        panel.pointerLocation = { .zero }
        defer { panel.closeImmediately() }
        var toggles = 0; panel.onTogglePlayback = { toggles += 1 }
        panel.present(); panel.contentView?.layoutSubtreeIfNeeded()
        func key(_ type: NSEvent.EventType = .keyDown, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49))
        }
        for point in [NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.midY),
                      NSPoint(x: panel.videoFrame.minX+12, y: panel.videoFrame.maxY-12),
                      NSPoint(x: panel.videoFrame.maxX-12, y: panel.videoFrame.minY+12)] {
            XCTAssertNil(panel.routeSpace(try key(), pointer: point))
        }
        XCTAssertEqual(toggles, 3)
        XCTAssertNil(panel.routeSpace(try key(repeating: true), pointer: panel.videoFrame.origin)); XCTAssertEqual(toggles, 3)
        XCTAssertNotNil(panel.routeSpace(try key(modifiers: .command), pointer: panel.videoFrame.origin))
        XCTAssertNotNil(panel.routeSpace(try key(), pointer: .zero))
        // F returns the video to its tab, as the arrows do, only over the picture too.
        var returns = 0; panel.onReturn = { returns += 1 }
        let f = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: UInt16(kVK_ANSI_F)))
        XCTAssertNotNil(panel.routeSpace(f, pointer: .zero)); XCTAssertEqual(returns, 0)
        XCTAssertNil(panel.routeSpace(f, pointer: NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.midY)))
        XCTAssertEqual(returns, 1); XCTAssertEqual(toggles, 3, "F doesn't play or pause")
        let controls = panel.overlay.subviews.compactMap { $0 as? FloatingVideoControl }
        XCTAssertEqual(controls.count, 2)
        XCTAssertLessThan(controls[0].frame.minX, 10*FloatingVideoOverlay.controlScale(width: panel.overlay.bounds.width))
        XCTAssertEqual(controls[0].frame.minY, controls[0].frame.minX)
        XCTAssertEqual(panel.overlay.bounds.maxX-controls[1].frame.maxX, controls[0].frame.minX, accuracy: 0.01)
    }

    @MainActor func testPiPButtonsUseDelayedNativeHintsThatFollowShiftAndDismissCleanly() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 360, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        let close = FloatingVideoControl(glyph: .cross, title: "Close Picture in Picture and pause video")
        let back = FloatingVideoControl(glyph: .arrows, title: "Return video to its tab")
        close.alternateAction = {}
        close.frame.origin = NSPoint(x: 20, y: 100); back.frame.origin = NSPoint(x: 300, y: 100)
        panel.contentView?.addSubview(close); panel.contentView?.addSubview(back)
        let closeHint = try XCTUnwrap(close.hoverHint), backHint = try XCTUnwrap(back.hoverHint)
        defer { closeHint.hide(); backHint.hide(); panel.orderOut(nil) }
        panel.orderFront(nil); panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNil(close.toolTip); XCTAssertNil(back.toolTip, "Neither button keeps the old system tooltip")
        func hover(_ button: FloatingVideoControl, _ type: NSEvent.EventType) throws {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if type == .mouseEntered { button.mouseEntered(with: event) } else { button.mouseExited(with: event) }
        }
        try hover(close, .mouseEntered)
        XCTAssertNil(closeHint.popover, "The normal hover delay applies")
        try await Task.sleep(for: .milliseconds(750))
        let popover = try XCTUnwrap(closeHint.popover)
        XCTAssertTrue(popover.isShown)
        let text = try XCTUnwrap(popover.contentViewController?.view.subviews.first as? NSTextField)
        XCTAssertEqual(text.stringValue, "Close Picture in Picture and pause video")
        close.updateModifiers(.shift)
        XCTAssertTrue(closeHint.popover === popover && popover.isShown, "Shift updates the same native popover")
        XCTAssertEqual(text.stringValue, "Hide Picture in Picture and keep playing")
        close.updateModifiers([])
        XCTAssertEqual(text.stringValue, "Close Picture in Picture and pause video")
        popover.animates = false
        try hover(close, .mouseExited)
        XCTAssertFalse(popover.isShown)

        try hover(back, .mouseEntered)
        try await Task.sleep(for: .milliseconds(750))
        let returnPopover = try XCTUnwrap(backHint.popover)
        XCTAssertTrue(returnPopover.isShown)
        XCTAssertEqual(backHint.text, "Return video to its tab")
        returnPopover.animates = false
        _ = back.accessibilityPerformPress()
        XCTAssertFalse(returnPopover.isShown, "Activating a PiP control closes its hint")
        try hover(close, .mouseEntered)
        close.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertFalse(popover.isShown, "Removing a custom glyph anchor cancels a pending hint")
    }

    @MainActor func testShiftMorphsOnlyTheHoveredXIntoAStationaryBar() throws {
        _ = NSApplication.shared
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main))
        defer { panel.closeImmediately() }
        panel.contentView?.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(panel.overlay.subviews.compactMap { $0 as? FloatingVideoControl }.first)
        let body = try XCTUnwrap(close.layer?.sublayers?.first)
        let strokes = try XCTUnwrap(body.sublayers?.compactMap { $0 as? CAShapeLayer })
        func hover(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if type == .mouseEntered { close.mouseEntered(with: event) } else { close.mouseExited(with: event) }
        }
        panel.overlay.updateModifiers(.shift)
        XCTAssertFalse(close.minimizesInBackground, "Holding Shift elsewhere does not change the X")
        try hover(.mouseEntered)
        let positions = strokes.map(\.position)
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        panel.sendEvent(flags)
        XCTAssertTrue(close.minimizesInBackground, "Shift changes it without moving the pointer")
        XCTAssertEqual(strokes.first?.path?.boundingBoxOfPath.height, 0)
        XCTAssertEqual(strokes.map(\.position), positions)
        XCTAssertTrue(strokes.allSatisfy { $0.animation(forKey: "hover") == nil }, "The bar has no downward hover motion")
        XCTAssertEqual(close.accessibilityLabel(), "Hide Picture in Picture and keep playing")
        panel.overlay.updateModifiers([])
        XCTAssertFalse(close.minimizesInBackground)
        try hover(.mouseExited)
        try hover(.mouseEntered, modifiers: .shift)
        XCTAssertTrue(close.minimizesInBackground, "Entering while Shift is already held also works")
        try hover(.mouseExited, modifiers: .shift)
        XCTAssertFalse(close.minimizesInBackground)
    }

    @MainActor func testSlowScrubbingContinuesThroughNativeMomentumAndCommitsPrecisely() {
        let bar = FloatingVideoProgressBar(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        var seeks: [(Double, Bool)] = []
        bar.seek = { seeks.append(($0, $1)) }
        bar.show(time: 500, duration: 1000)
        bar.handleScroll(.init(phase: .began, timestamp: 1))
        bar.handleScroll(.init(phase: .changed, translation: CGVector(dx: 100, dy: 0), timestamp: 1.1))
        XCTAssertEqual(bar.fraction, 0.505, accuracy: 0.00001)
        bar.show(time: 490, duration: 1000)
        XCTAssertEqual(bar.fraction, 0.505, accuracy: 0.00001, "An old playback report cannot jump the scrub backwards")
        bar.handleScroll(.init(phase: .ended, timestamp: 1.2))
        XCTAssertTrue(bar.isTrackpadScrubbing)
        bar.handleScroll(.init(phase: [], momentumPhase: .changed, translation: CGVector(dx: 200, dy: 0), timestamp: 1.3))
        XCTAssertEqual(bar.fraction, 0.515, accuracy: 0.00001)
        bar.handleScroll(.init(phase: [], momentumPhase: .ended, timestamp: 1.4))
        XCTAssertFalse(bar.isScrubbing); XCTAssertFalse(bar.isTrackpadScrubbing)
        XCTAssertEqual(seeks.last?.0 ?? 0, 0.515, accuracy: 0.00001)
        XCTAssertEqual(seeks.last?.1, true, "The final seek lands exactly after the flick")
    }

    @MainActor func testSeeksClampAtBothEndsAndAQuietFingerLiftFinishes() async throws {
        let bar = FloatingVideoProgressBar(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        var final = false
        bar.seek = { _, finished in final = finished }
        bar.show(time: 1, duration: 10)
        bar.handleScroll(.init(phase: .began, translation: CGVector(dx: -1000, dy: 0), timestamp: 1))
        XCTAssertEqual(bar.fraction, 0)
        bar.handleScroll(.init(phase: .changed, translation: CGVector(dx: 1000, dy: 0), timestamp: 1.1))
        XCTAssertEqual(bar.fraction, 1)
        bar.handleScroll(.init(phase: .ended, timestamp: 1.2))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(bar.isTrackpadScrubbing); XCTAssertTrue(final)
        bar.show(time: 0, duration: .infinity)
        bar.handleScroll(.init(phase: .began, translation: CGVector(dx: 100, dy: 0), timestamp: 2))
        XCTAssertFalse(bar.isScrubbing, "A live stream without a duration cannot be scrubbed")
    }

    @MainActor func testSeekGestureNeverMovesWindowAndMovementNeverBecomesASeekMidGesture() throws {
        _ = NSApplication.shared
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main))
        defer { panel.closeImmediately() }
        panel.contentView?.layoutSubtreeIfNeeded()
        let bar = panel.overlay.progress
        bar.show(time: 10, duration: 100)
        let point = panel.convertPoint(toScreen: bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil))
        let frame = panel.frame
        panel.handleScroll(.init(phase: .began, timestamp: 1), pointer: point)
        panel.handleScroll(.init(phase: .changed, translation: CGVector(dx: 100, dy: 0), timestamp: 1.1), pointer: .zero)
        panel.handleScroll(.init(phase: .ended, timestamp: 1.2), pointer: .zero)
        panel.handleScroll(.init(phase: [], momentumPhase: .changed, translation: CGVector(dx: 100, dy: 0), timestamp: 1.3), pointer: .zero)
        XCTAssertEqual(panel.frame, frame); XCTAssertFalse(panel.isDragging)
        XCTAssertEqual(bar.fraction, 0.20, accuracy: 0.0001)
        panel.handleScroll(.init(phase: [], momentumPhase: .ended, timestamp: 1.4), pointer: .zero)
        let outside = NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.midY)
        panel.handleScroll(.init(phase: .began, timestamp: 2), pointer: outside)
        panel.handleScroll(.init(phase: .changed, translation: CGVector(dx: -20, dy: 0), timestamp: 2.1), pointer: point)
        XCTAssertTrue(panel.isDragging); XCTAssertFalse(bar.isTrackpadScrubbing)
        panel.handleScroll(.init(phase: .ended, timestamp: 2.2), pointer: point)
    }

    @MainActor func testDraggingAnEdgeResizesKeepingItsShapeAndRedrawsOnceLetGo() throws {
        _ = NSApplication.shared
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main))
        defer { panel.closeImmediately() }
        panel.present(); panel.contentView?.layoutSubtreeIfNeeded()
        var sizes: [NSSize] = []; panel.onVideoSizeChange = { size, _ in sizes.append(size) }
        let start = panel.videoFrame
        var pointer = NSPoint(x: start.minX+1, y: start.midY)
        panel.pointerLocation = { pointer }
        XCTAssertEqual(panel.resizeHandle(at: pointer), .init(x: -1, y: 0))
        XCTAssertNil(panel.resizeHandle(at: NSPoint(x: start.midX, y: start.midY)))
        XCTAssertTrue(panel.contentView?.hitTest(panel.convertPoint(fromScreen: pointer)) is FloatingResizeEdges, "The edge takes the press")
        XCTAssertFalse(panel.contentView?.hitTest(panel.convertPoint(fromScreen: NSPoint(x: start.midX, y: start.midY))) is FloatingResizeEdges)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.handleEdgeResize(try mouse(.leftMouseDown))
        XCTAssertTrue(panel.isResizingFromEdge)
        pointer.x -= 60; pointer.y += 30
        panel.handleEdgeResize(try mouse(.leftMouseDragged))
        XCTAssertEqual(panel.videoFrame.width, start.width+60, accuracy: 1)
        XCTAssertEqual(panel.videoFrame.maxX, start.maxX, accuracy: 1, "The right side stays")
        XCTAssertEqual(panel.videoFrame.width/panel.videoFrame.height, start.width/start.height, accuracy: 0.01)
        XCTAssertTrue(sizes.isEmpty, "The picture stretches until it's let go")
        panel.handleEdgeResize(try mouse(.leftMouseUp))
        XCTAssertFalse(panel.isResizingFromEdge)
        XCTAssertEqual(sizes.last?.width ?? 0, panel.videoFrame.width, accuracy: 0.5)
        XCTAssertEqual(sizes.count, 1)
    }

    @MainActor func testATuckedWindowsMenuPlaysOrPausesAndUntucks() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let placement = FloatingVideoWindow.Placement(videoFrame: NSRect(x: screen.visibleFrame.minX+20, y: screen.visibleFrame.midY, width: 360, height: 202.5), tucked: .left)
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: screen, placement: placement)
        defer { panel.closeImmediately() }
        panel.present(); panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.tuckedEdge, .left)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        panel.showPlayback(paused: false)
        XCTAssertEqual(panel.tuckHandle.menu(for: click)?.items.map(\.title), ["Pause", "Untuck"])
        panel.showPlayback(paused: true)
        let menu = try XCTUnwrap(panel.tuckHandle.menu(for: click))
        XCTAssertEqual(menu.items.map(\.title), ["Play", "Untuck"])
        var toggles = 0; panel.onTogglePlayback = { toggles += 1 }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(toggles, 1)
        XCTAssertNil(panel.resizeHandle(at: NSPoint(x: panel.videoFrame.maxX-1, y: panel.videoFrame.midY)), "No resizing while tucked")
        menu.performActionForItem(at: 1)
        XCTAssertNil(panel.tuckedEdge)
        XCTAssertNil(panel.tuckHandle.menu(for: click), "Out on the screen, the picture's own clicks are back")
    }

    @MainActor func testAPinchWhoseEndNeverComesStopsHoldingTheWindow() async throws {
        _ = NSApplication.shared
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main))
        defer { panel.closeImmediately() }
        panel.present(); panel.contentView?.layoutSubtreeIfNeeded()
        panel.abandonedPinchTimeout = 0.05
        panel.handleMagnification(0.2, phase: .began)
        panel.handleMagnification(0.1, phase: .changed)
        let middle = NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.midY)
        panel.handleScroll(.init(phase: .began, timestamp: 1), pointer: middle)
        XCTAssertFalse(panel.isDragging, "Mid-pinch, two fingers don't move it")
        try await Task.sleep(for: .milliseconds(300))
        panel.handleScroll(.init(phase: .began, timestamp: 2), pointer: middle)
        XCTAssertTrue(panel.isDragging, "The quiet pinch ended, so they do")
        panel.handleScroll(.init(phase: .ended, timestamp: 2.1), pointer: middle)
    }
}
