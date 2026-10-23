import Foundation
import os

/// Local macOS unified logs only. Never pass URLs, account names, credentials, messages or keys.
enum AuthenticationDiagnostics {
    static let engine = Logger(subsystem: "dev.bartosz.Rise", category: "AuthenticationSetup")
    static let hosts = Logger(subsystem: "dev.bartosz.Rise", category: "NativeMessaging")
    static let popups = Logger(subsystem: "dev.bartosz.Rise", category: "ExtensionPopup")

    static func startup(isolated: Bool, packaged: Bool) {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile") != nil
            || FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path)
        let cloud = Bundle.main.object(forInfoDictionaryKey: "RiseCloudKitEnabled") as? Bool ?? false
        engine.notice("Startup isolated=\(isolated) framework=\(packaged) provisioningProfile=\(profile) cloudKit=\(cloud)")
    }

    static func hostFailure(_ phase: String, _ error: Error) {
        let error = error as NSError
        // localizedDescription/userInfo can contain private paths; retain only domain and code.
        hosts.error("Host registration failed phase=\(phase, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)")
    }
}
