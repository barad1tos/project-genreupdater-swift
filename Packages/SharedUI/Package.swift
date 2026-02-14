// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SharedUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SharedUI", targets: ["SharedUI"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "SharedUI",
            dependencies: ["Core"],
            path: "Sources/SharedUI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SharedUITests",
            dependencies: ["SharedUI"],
            path: "Tests/SharedUITests"
        ),
    ]
)
