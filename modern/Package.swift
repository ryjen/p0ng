// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PongCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PongCore", targets: ["PongCore"])],
    targets: [
        .target(name: "PongCore"),
        .testTarget(name: "PongCoreTests", dependencies: ["PongCore"])
    ]
)
