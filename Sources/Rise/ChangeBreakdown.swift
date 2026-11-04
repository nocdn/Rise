import Foundation

/// How a pull request's lines split between code, tests, mocks, generated files and docs, as
/// T3 Code shows it (pingdotgg/t3code#22189): each changed file sorted by its path alone.
/// A split saved before docs were counted has no `docs` and doesn't decode, so it's read again.
struct ChangeBreakdown: Equatable, Codable {
    struct Lines: Equatable, Codable {
        var additions = 0, deletions = 0
        var isEmpty: Bool { additions == 0 && deletions == 0 }
    }
    enum Kind: String, CaseIterable {
        /// T3 Code's order.
        case code, tests, mocks, generated, docs
        var title: String {
            switch self { case .code: "Code"; case .tests: "Tests"; case .mocks: "Mocks"; case .generated: "Generated"; case .docs: "Docs" }
        }
    }
    var code = Lines(), tests = Lines(), mocks = Lines(), generated = Lines(), docs = Lines()

    subscript(kind: Kind) -> Lines {
        get {
            switch kind { case .code: code; case .tests: tests; case .mocks: mocks; case .generated: generated; case .docs: docs }
        }
        set {
            switch kind {
            case .code: code = newValue; case .tests: tests = newValue; case .mocks: mocks = newValue
            case .generated: generated = newValue; case .docs: docs = newValue
            }
        }
    }
    mutating func add(path: String, additions: Int, deletions: Int) {
        let kind = Self.kind(ofPath: path)
        self[kind].additions += additions; self[kind].deletions += deletions
    }
    /// A unified diff, as `git diff` writes it, read file by file: the lines added and removed in
    /// each file's hunks, by its new path, and their sum. A file's header lines, such as `--- a/…`,
    /// aren't lines of it, though a removed line can start the same way inside a hunk.
    static func read(diff: String) -> (breakdown: ChangeBreakdown, lines: Lines) {
        var breakdown = ChangeBreakdown(), total = Lines()
        var path = "", lines = Lines(), inHunk = false, started = false
        func finish() { if started { breakdown.add(path: path, additions: lines.additions, deletions: lines.deletions) } }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finish()
                started = true; inHunk = false; lines = Lines()
                path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? ""
            } else if !inHunk, line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
            } else if line.hasPrefix("@@") {
                inHunk = true
            } else if inHunk, line.hasPrefix("+") {
                lines.additions += 1; total.additions += 1
            } else if inHunk, line.hasPrefix("-") {
                lines.deletions += 1; total.deletions += 1
            }
        }
        finish()
        return (breakdown, total)
    }

    // MARK: Sorting a file by its path, as T3 Code's changedFileKind.ts does

    private static let generatedFiles: Set<String> = [
        "bun.lock", "bun.lockb", "cargo.lock", "composer.lock", "deno.lock", "flake.lock", "gemfile.lock", "go.sum",
        "gradle.lockfile", "mix.lock", "npm-shrinkwrap.json", "package-lock.json", "packages.lock.json", "pipfile.lock",
        "pnpm-lock.yaml", "podfile.lock", "poetry.lock", "pubspec.lock", "uv.lock", "yarn.lock",
    ]
    private static let generatedName = regex(#"(\.generated\.|\.gen\.|\.g\.dart$|\.pb\.go$|_pb2(_grpc)?\.py$|\.pb\.(cc|h)$|\.min\.(js|css)$|\.(js|css)\.map$)"#)
    private static let generatedDirectories: Set<String> = ["__generated__", "_generated", "generated"]
    private static let mockName = regex(#"(\.snap$|\.(mocks?|fixtures?|stubs?|fakes?)\.[^.]+$|^(mocks?|fixtures?|stubs?|fakes?)([-_.A-Z]|$))"#)
    private static let mockDirectories: Set<String> = [
        "__fixtures__", "__mocks__", "__snapshots__", "fakes", "fixture", "fixtures", "mock", "mocks", "stubs", "testdata",
    ]
    private static let testName = regex(#"(\.(test|spec|e2e|eval)\.[^.]+$|_(test|spec)\.[^.]+$|^test_.+\.py$|^conftest\.py$|^(vitest|jest)\.setup\.[^.]+$)"#, caseInsensitive: true)
    /// Case-sensitive: `FooTest.java` is a test class, `Latest.java` isn't.
    private static let classTestName = regex(#"(Tests?|Spec)\.(java|kt|kts|scala|groovy|cs|php|swift|m)$"#)
    private static let testDirectories: Set<String> = ["__tests__", "__test__", "cypress", "e2e", "evals", "spec", "specs", "test", "tests"]

    private static let docsName = regex(#"\.(md|mdx|markdown|rst|adoc|txt)$"#, caseInsensitive: true)
    /// Plain-text files that tools read as config or input, not prose.
    private static let notDocsName = regex(#"^(requirements.*|constraints.*|CMakeLists|robots|llms)\.txt$"#, caseInsensitive: true)

    /// Lockfiles and build output are generated; mocks, fixtures and snapshots are kept apart
    /// from the tests themselves; prose (Markdown, plain text) is docs; everything else is code.
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
        if matches(docsName) && !matches(notDocsName) { return .docs }
        return .code
    }
    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
