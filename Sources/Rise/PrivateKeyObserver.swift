import Foundation

/// Observes a key that has no Swift key path, such as a private WebKit property.
/// Does nothing when the object does not have the key.
final class PrivateKeyObserver: NSObject {
    private weak var object: NSObject?
    private let key: String
    private let changed: () -> Void
    init(_ object: NSObject, key: String, changed: @escaping () -> Void) {
        self.key = key; self.changed = changed
        super.init()
        guard object.responds(to: NSSelectorFromString(key)) else { return }
        self.object = object
        object.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }
    deinit { object?.removeObserver(self, forKeyPath: key) }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == key { changed() }
    }
}
