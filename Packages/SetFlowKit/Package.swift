// swift-tools-version: 6.2

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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SetFlowKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SetFlowKitTests",
            dependencies: [
                "SetFlowKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Fixtures/v1.sql"),
                .copy("Fixtures/backup-v1.json"),
                .copy("Fixtures/backup-v2.json"),
            ]
        ),
    ]
)
