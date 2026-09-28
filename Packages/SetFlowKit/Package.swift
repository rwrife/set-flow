// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SetFlowKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SetFlowKit", targets: ["SetFlowKit"]),
    ],
    targets: [
        .target(name: "SetFlowKit"),
        .testTarget(name: "SetFlowKitTests", dependencies: ["SetFlowKit"]),
    ]
)
