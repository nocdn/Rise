import Foundation
import CryptoKit

/// No cookies, headers, form bodies, element text, URL credentials, query values,
/// or fragments enter a diagnostic record. Policy always uses the original URL.
enum PopupLogURL {
    private static let correlationKey = SymmetricKey(size: .bits256)
    static func fingerprint(_ url: URL?) -> String? {
        guard let url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let bytes = Data(PopupDestinationRules.canonical(url).absoluteString.prefix(16384).utf8)
        return HMAC<SHA256>.authenticationCode(for: bytes, using: correlationKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func describe(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "about" { return ["blank", "srcdoc"].contains(url.path) ? "about:"+url.path : "about:<redacted>" }
        if scheme == "blob" {
            let origin = URL(string: String(url.absoluteString.dropFirst(5)))
            return "blob:"+(origin?.host.map { (origin?.scheme ?? "https")+"://"+$0 } ?? "<opaque>")+"/<redacted>"
        }
        guard ["http", "https"].contains(scheme), var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return scheme+":<redacted>" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        let secretSegments: Set<String> = ["token", "tokens", "password", "reset", "session", "sessions", "invite", "verify", "verification", "authorization"]
        var hideNext = false
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let value = String(segment)
            defer { hideNext = secretSegments.contains(value.lowercased()) }
            if hideNext || value.count > 64 || value.contains("@") || value.hasPrefix("eyJ") { return "<redacted>" }
            return value
        }.joined(separator: "/")
        parts.path = String(path.prefix(1024))
        // Keep names to distinguish routes and auth flows, never their values.
        let names = Set((parts.queryItems ?? []).prefix(32).map { String($0.name.prefix(64)) })
        parts.queryItems = names.isEmpty ? nil : names.sorted().map { URLQueryItem(name: $0, value: "<redacted>") }
        return parts.url?.absoluteString
    }
}

struct PopupLogRecord: Codable, Sendable {
    let schema: Int
    let id: String
    let timestamp: Date
    let runID: String
    let policyID: String
    let privateMode: Bool
    let event: String
    let pageID: String?
    let documentID: String?
    let chainID: String?
    let requestID: String?
    let source: String?
    let destination: String?
    let frame: String?
    let sourceFingerprint: String?
    let destinationFingerprint: String?
    let details: [String: String]
    let rules: PopupDestinationRules.Evaluation?

    init(runID: String, policyID: String, privateMode: Bool, event: String,
         pageID: String? = nil, documentID: String? = nil, chainID: String? = nil, requestID: String? = nil,
         source: URL? = nil, destination: URL? = nil, frame: URL? = nil,
         details: [String: String] = [:], rules: PopupDestinationRules.Evaluation? = nil, timestamp: Date = Date()) {
        schema = 1; id = UUID().uuidString; self.timestamp = timestamp
        self.runID = runID; self.policyID = policyID; self.privateMode = privateMode; self.event = event
        self.pageID = pageID; self.documentID = documentID; self.chainID = chainID; self.requestID = requestID
        self.source = PopupLogURL.describe(source); self.destination = PopupLogURL.describe(destination); self.frame = PopupLogURL.describe(frame)
        sourceFingerprint = PopupLogURL.fingerprint(source); destinationFingerprint = PopupLogURL.fingerprint(destination)
        self.details = details.mapValues { String($0.prefix(2048)) }; self.rules = rules
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }
}

struct PopupLogSnapshot: Codable, Sendable {
    let schema: Int
    let exportedAt: Date
    let privateSession: Bool
    let notes: String
    let writeFailures: Int
    let unreadableLines: Int
    let evictedMemoryEvents: Int
    let queueDroppedEvents: Int
    let events: [PopupLogRecord]
}
