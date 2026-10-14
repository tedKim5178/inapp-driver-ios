// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InAppDriver",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "InAppDriver", targets: ["InAppDriver"]),
    ],
    targets: [
        // No dependencies: the control server is built on Network.framework.
        .target(name: "InAppDriver"),
        .testTarget(name: "InAppDriverTests", dependencies: ["InAppDriver"]),
    ]
)
