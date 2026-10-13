// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Rise links its Chromium engine only where it has been built (see Engine/README.md);
// everywhere else it builds as before, on WebKit alone.
let engineRoot = ProcessInfo.processInfo.environment["RISE_CHROMIUM_ROOT"]
    ?? URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().appendingPathComponent("rise-chromium").path
let cef = engineRoot + "/distrib/current"
let cefWrapper = engineRoot + "/bridge-build/wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a"
let hasChromium = FileManager.default.fileExists(atPath: cef + "/include/cef_app.h") && FileManager.default.fileExists(atPath: cefWrapper)
// Ad blocking for Chromium pages, built from Engine/adblock by scripts/build.sh where cargo is.
let adBlock = engineRoot + "/adblock-build/release/librise_adblock.a"
let hasAdBlock = FileManager.default.fileExists(atPath: adBlock)
// The settings CEF's own samples build their code with.
let cefFlags: [CXXSetting] = [.unsafeFlags(["-I", cef, "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fobjc-arc"])]
let cefLinking: [LinkerSetting] = [.unsafeFlags([cefWrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]

var targets: [Target] = [
    .target(name: "RiseCore"),
    .executableTarget(name: "Rise", dependencies: ["RiseCore"] + (hasChromium ? ["RiseChromium"] : []),
                      resources: [.copy("Resources/Blocking")],
                      swiftSettings: hasChromium ? [.define("RISE_CHROMIUM")] : []),
    .testTarget(name: "RiseCoreTests", dependencies: ["RiseCore"]),
    .testTarget(name: "RiseTests", dependencies: ["Rise", "RiseCore"], resources: [.copy("Resources")],
                swiftSettings: hasChromium ? [.define("RISE_CHROMIUM")] : []),
]
var products: [Product] = [.executable(name: "Rise", targets: ["Rise"])]
if hasChromium {
    targets += [
        .target(name: "RiseChromium", cxxSettings: cefFlags + (hasAdBlock ? [.define("RISE_ADBLOCK")] : []),
                linkerSettings: cefLinking + (hasAdBlock ? [.unsafeFlags([adBlock])] : [])),
        .executableTarget(name: "RiseHelper", cxxSettings: cefFlags + [.define("CEF_USE_SANDBOX")], linkerSettings: cefLinking),
    ]
    products.append(.executable(name: "RiseHelper", targets: ["RiseHelper"]))
}

let package = Package(name: "Rise", platforms: [.macOS(.v14)], products: products, targets: targets)
