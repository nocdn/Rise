// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Rise runs on its own Chromium fork (Engine/README.md), whose framework holds the engine, built
// beside the repo by scripts/engine/build.sh; Rise only takes its interface's header.
let engineRoot = ProcessInfo.processInfo.environment["RISE_CHROMIUM_ROOT"]
    ?? URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().appendingPathComponent("rise-chromium").path
let frameworks = engineRoot + "/fork/src/out/Official/Chromium.app/Contents/Frameworks"

// Sparkle updates the Mac app from the appcast on GitHub Releases (docs/Releasing.md); pinned, as the
// release script signs its parts by path.
let package = Package(name: "Rise", platforms: [.macOS(.v14)], products: [.executable(name: "Rise", targets: ["Rise"])],
                      dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")], targets: [
    .target(name: "RiseCore"),
    .target(name: "RiseChromium",
            linkerSettings: [.unsafeFlags(["-F", frameworks, "-framework", "Chromium Framework",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "Rise", dependencies: ["RiseCore", "RiseChromium", .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/SelectionBase64.svg")]),
    .testTarget(name: "RiseCoreTests", dependencies: ["RiseCore"], resources: [.copy("Resources")]),
    // Run with scripts/test.sh, which finds the engine's framework for them; they don't start it.
    .testTarget(name: "RiseTests", dependencies: ["Rise", "RiseCore"], resources: [.copy("Resources")]),
])
