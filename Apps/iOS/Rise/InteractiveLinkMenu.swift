import UIKit
import WebKit
import ObjectiveC

/// UIKit's native preview/menu layout, with touches delivered to the live preview.
/// UIKit has no public interactive-preview switch. Keep the compatibility hook on
/// only this web view's interaction (never swizzle UIKit or WebKit globally). If
/// its selectors change, the ordinary native preview remains available.
@MainActor enum InteractiveLinkMenu {
    private static var enabledKey: UInt8 = 0
    private static var subclasses: [ObjectIdentifier: AnyClass] = [:]
    private static let presentationSelector = NSSelectorFromString("clickPresentationInteraction:presentationForPresentingViewController:")

    static func setEnabled(_ enabled: Bool, in page: WKWebView) {
        for interaction in interactions(in: page) {
            setEnabled(enabled, on: interaction)
        }
    }
    static func setEnabled(_ enabled: Bool, on interaction: UIContextMenuInteraction) {
        if enabled { install(on: interaction) }
        objc_setAssociatedObject(interaction, &enabledKey, NSNumber(value: enabled), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Recent WebKit owns the interaction through its text-interaction wrapper,
    /// rather than exposing it directly in UIView.interactions.
    static func interactions(in page: WKWebView) -> [UIContextMenuInteraction] {
        var result: [UIContextMenuInteraction] = [], seen = Set<ObjectIdentifier>()
        func append(_ interaction: UIContextMenuInteraction) {
            if seen.insert(ObjectIdentifier(interaction)).inserted { result.append(interaction) }
        }
        func visit(_ view: UIView) {
            if NSStringFromClass(type(of: view)).contains("WKContentView") {
                let selector = NSSelectorFromString("contextMenuInteraction")
                if view.responds(to: selector),
                   let interaction = view.perform(selector)?.takeUnretainedValue() as? UIContextMenuInteraction { append(interaction) }
            }
            for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                guard let delegate = interaction.delegate,
                      NSStringFromClass(type(of: delegate)).contains("WKContentView") else { continue }
                append(interaction)
            }
            view.subviews.forEach(visit)
        }
        visit(page)
        return result
    }

    /// Refreshing a native row can reset both the list offset and the platter's
    /// expanded position. Transfer them to the updated menu in the same transaction.
    static func updateVisibleMenu(on interaction: UIContextMenuInteraction,
                                  _ update: @escaping (UIMenu) -> UIMenu) -> Bool {
        let controller = visibleMenuController(for: interaction)
        let menu = controller.flatMap { object($0, "menuView") }
        let scroll = menu.flatMap(menuScrollView)
        let pan = controller.flatMap { object($0, "platterPanController") }
        let gesture = pan.flatMap { object($0, "panGestureRecognizer") } as? UIPanGestureRecognizer
        guard scroll?.isTracking != true, scroll?.isDragging != true, scroll?.isDecelerating != true,
              gesture?.state != .began, gesture?.state != .changed else { return false }

        let offset = scroll?.contentOffset
        let detent = pan.flatMap(currentDetent)
        NativeMenuLoading.withoutAnimation {
            interaction.updateVisibleMenu(update)
            if let controller, let pan = object(controller, "platterPanController"),
               let detent, let current = currentDetent(in: pan), current != detent {
                restoreDetent(detent, in: pan)
            }
            if let offset, let controller, let menu = object(controller, "menuView"),
               let updatedScroll = menuScrollView(in: menu), updatedScroll.contentOffset != offset {
                updatedScroll.setContentOffset(offset, animated: false)
            }
        }
        return true
    }

    private static func visibleMenuController(for interaction: UIContextMenuInteraction) -> NSObject? {
        guard let presentations = object(interaction, "presentationsByIdentifier") as? [AnyHashable: NSObject] else { return nil }
        let visible = presentations.values.compactMap { object($0, "uiController") }.filter {
            (object($0, "menuView") as? UIView)?.window != nil
        }
        return visible.count == 1 ? visible.first : nil
    }

    private static func menuScrollView(in menu: NSObject) -> UIScrollView? {
        guard let list = object(menu, "currentListView") else { return nil }
        return object(list, "collectionView") as? UIScrollView
    }

    private static func currentDetent(in pan: NSObject) -> Int? {
        guard let ivar = class_getInstanceVariable(type(of: pan), "_currentDetentIndex"),
              let encoding = ivar_getTypeEncoding(ivar), String(cString: encoding) == "Q",
              let detents = object(pan, "detents") as? NSArray else { return nil }
        let index = Unmanaged.passUnretained(pan).toOpaque().load(fromByteOffset: ivar_getOffset(ivar), as: UInt.self)
        return index < UInt(detents.count) ? Int(index) : nil
    }

    private static func restoreDetent(_ detent: Int, in pan: NSObject) {
        let selector = NSSelectorFromString("moveToDetentPosition:updateScrubPath:")
        guard let detents = object(pan, "detents") as? NSArray, detent < detents.count,
              let method = class_getInstanceMethod(type(of: pan), selector),
              let encoding = method_getTypeEncoding(method), String(cString: encoding) == "v28@0:8q16B24" else { return }
        typealias Move = @convention(c) (NSObject, Selector, Int, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Move.self)(pan, selector, detent, false)
    }

    private static func install(on interaction: UIContextMenuInteraction) {
        guard let originalClass = object_getClass(interaction),
              !NSStringFromClass(originalClass).hasPrefix("RiseInteractiveLinkMenu_"),
              let method = class_getInstanceMethod(originalClass, presentationSelector),
              method_getNumberOfArguments(method) == 4 else { return }
        let key = ObjectIdentifier(originalClass)
        if let subclass = subclasses[key] { object_setClass(interaction, subclass); return }
        let name = "RiseInteractiveLinkMenu_"+NSStringFromClass(originalClass)
        guard let subclass = objc_allocateClassPair(originalClass, name, 0) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let selector = presentationSelector
        let block: @convention(block) (NSObject, NSObject, UIViewController) -> AnyObject? = { interaction, driver, presenter in
            let presentation = original(interaction, selector, driver, presenter)?.takeUnretainedValue()
            MainActor.assumeIsolated {
                if (objc_getAssociatedObject(interaction, &enabledKey) as? NSNumber)?.boolValue == true,
                   let presentation = presentation as? NSObject { enablePreview(in: presentation) }
            }
            return presentation
        }
        guard class_addMethod(subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method)) else {
            objc_disposeClassPair(subclass); return
        }
        objc_registerClassPair(subclass)
        subclasses[key] = subclass
        object_setClass(interaction, subclass)
    }

    private static func object(_ source: NSObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: source), selector),
              let encoding = method_getTypeEncoding(method), String(cString: encoding).hasPrefix("@") else { return nil }
        return source.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func enablePreview(in presentation: NSObject) {
        guard let controller = object(presentation, "uiController"),
              let originalStyle = object(controller, "menuStyle") as? NSCopying,
              let style = originalStyle.copy(with: nil) as? NSObject,
              style.responds(to: NSSelectorFromString("setHasInteractivePreview:")),
              controller.responds(to: NSSelectorFromString("setMenuStyle:")) else { return }
        style.setValue(true, forKey: "hasInteractivePreview")
        if style.responds(to: NSSelectorFromString("setPreventPreviewRasterization:")) {
            style.setValue(true, forKey: "preventPreviewRasterization")
        }
        controller.perform(NSSelectorFromString("setMenuStyle:"), with: style)
    }
}
