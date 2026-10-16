import AppKit

@main @MainActor struct RiseMain {
    static func main() {
        let app = ChromiumEngine.makeApplication()
        ChromiumEngine.start()
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
