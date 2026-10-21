import UIKit

/// The first keyboard a launch brings up is slow: UIKit loads its input views, layouts and text
/// services then, and the keyboard's own process lays out the keys and suggestions. Focusing a
/// hidden, off-screen field and letting it go in the same turn of the run loop does that early,
/// with nothing shown. The field copies the traits of the one it warms for, so the same keyboard
/// (its return key, its suggestions) is the one loaded.
@MainActor enum KeyboardWarmer {
    private(set) static var warmed = false

    static func warm(in window: UIWindow?, like model: UITextField? = nil) {
        guard !warmed, let window else { return }
        warmed = true
        let field = UITextField(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        if let model {
            field.keyboardType = model.keyboardType
            field.returnKeyType = model.returnKeyType
            field.enablesReturnKeyAutomatically = model.enablesReturnKeyAutomatically
            field.autocorrectionType = model.autocorrectionType
            field.spellCheckingType = model.spellCheckingType
            field.autocapitalizationType = model.autocapitalizationType
            field.textContentType = model.textContentType
        }
        field.alpha = 0
        window.addSubview(field)
        UIView.performWithoutAnimation {
            field.becomeFirstResponder()
            field.resignFirstResponder()
        }
        field.removeFromSuperview()
    }
}
