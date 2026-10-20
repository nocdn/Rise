import Foundation

/// How a pull request's lines split between code, tests, mocks and generated files, as T3 Code
/// shows it (pingdotgg/t3code#22189): each changed file sorted by its path alone.
struct ChangeBreakdown: Equatable, Codable {
    struct Lines: Equatable, Codable {
        var additions = 0, deletions = 0
        var isEmpty: Bool { additions == 0 && deletions == 0 }
    }
    enum Kind: String, CaseIterable {
        case code, tests, mocks, generated
        var title: String {
            switch self { case .code: "Code"; case .tests: "Tests"; case .mocks: "Mocks"; case .generated: "Generated" }
        }
    }
    var code = Lines(), tests = Lines(), mocks = Lines(), generated = Lines()

    subscript(kind: Kind) -> Lines {
        get {
            switch kind { case .code: code; case .tests: tests; case .mocks: mocks; case .generated: generated }
        }
        set {
            switch kind { case .code: code = newValue; case .tests: tests = newValue; case .mocks: mocks = newValue; case .generated: generated = newValue }
        }
    }
    mutating func add(path: String, additions: Int, deletions: Int) {
        let kind = Self.kind(ofPath: path)
        self[kind].additions += additions; self[kind].deletions += deletions
    }

    // MARK: Sorting a file by its path, as T3 Code's changedFileKind.ts does

    private static let generatedFiles: Set<String> = [
        "bun.lock", "bun.lockb", "cargo.lock", "composer.lock", "deno.lock", "flake.lock", "gemfile.lock", "go.sum",
        "gradle.lockfile", "mix.lock", "npm-shrinkwrap.json", "package-lock.json", "packages.lock.json", "pipfile.lock",
        "pnpm-lock.yaml", "podfile.lock", "poetry.lock", "pubspec.lock", "uv.lock", "yarn.lock",
    ]
    private static let generatedName = regex(#"(\.generated\.|\.gen\.|\.g\.dart$|\.pb\.go$|_pb2(_grpc)?\.py$|\.pb\.(cc|h)$|\.min\.(js|css)$|\.(js|css)\.map$)"#)
    private static let generatedDirectories: Set<String> = ["__generated__", "generated"]
    private static let mockName = regex(#"(\.snap$|\.(mocks?|fixtures?|stubs?|fakes?)\.[^.]+$|^(mocks?|fixtures?|stubs?|fakes?)([-_.A-Z]|$))"#)
    private static let mockDirectories: Set<String> = [
        "__fixtures__", "__mocks__", "__snapshots__", "fakes", "fixture", "fixtures", "mock", "mocks", "stubs", "testdata",
    ]
    private static let testName = regex(#"(\.(test|spec|e2e)\.[^.]+$|_(test|spec)\.[^.]+$|^test_.+\.py$|^conftest\.py$|^(vitest|jest)\.setup\.[^.]+$)"#, caseInsensitive: true)
    /// Case-sensitive: `FooTest.java` is a test class, `Latest.java` isn't.
    private static let classTestName = regex(#"(Tests?|Spec)\.(java|kt|kts|scala|groovy|cs|php|swift|m)$"#)
    private static let testDirectories: Set<String> = ["__tests__", "__test__", "cypress", "e2e", "spec", "specs", "test", "tests"]

    /// Lockfiles and build output are generated; mocks, fixtures and snapshots are kept apart
    /// from the tests themselves; everything else is code.
    static func kind(ofPath path: String) -> Kind {
        var segments = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = segments.popLast() ?? ""
        let directories = Set(segments.map { $0.lowercased() })
        func matches(_ pattern: NSRegularExpression) -> Bool {
            pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        if generatedFiles.contains(name.lowercased()) || matches(generatedName) || !directories.isDisjoint(with: generatedDirectories) { return .generated }
        if matches(mockName) || !directories.isDisjoint(with: mockDirectories) { return .mocks }
        if matches(testName) || matches(classTestName) || !directories.isDisjoint(with: testDirectories) { return .tests }
        return .code
    }
    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
