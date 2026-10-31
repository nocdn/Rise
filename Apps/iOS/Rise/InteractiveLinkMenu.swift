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

    private static func enablePreview(in presentation: NSObject) {
        func object(_ source: NSObject, _ name: String) -> NSObject? {
            let selector = NSSelectorFromString(name)
            guard source.responds(to: selector) else { return nil }
            return source.perform(selector)?.takeUnretainedValue() as? NSObject
        }
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
