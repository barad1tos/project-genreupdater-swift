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
        .package(url: "https://github.com/JakubMazur/lucide-icons-swift.git", from: "0.575.0"),
    ],
    targets: [
        .target(
            name: "SharedUI",
            dependencies: [
                "Core",
                .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
                .product(name: "LucideIcons", package: "lucide-icons-swift"),
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
