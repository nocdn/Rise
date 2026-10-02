// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Rise", platforms: [.macOS(.v14)], products: [.executable(name: "Rise", targets: ["Rise"])], targets: [.target(name: "RiseCore"), .executableTarget(name: "Rise", dependencies: ["RiseCore"]), .testTarget(name: "RiseCoreTests", dependencies: ["RiseCore"]), .testTarget(name: "RiseTests", dependencies: ["Rise", "RiseCore"])])
