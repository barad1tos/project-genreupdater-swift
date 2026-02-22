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
        .package(url: "https://github.com/markiv/SwiftUI-Shimmer.git", from: "1.5.1"),
    ],
    targets: [
        .target(
            name: "SharedUI",
            dependencies: [
                "Core",
                .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
            ],
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
