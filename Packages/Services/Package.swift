// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Services",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Services", targets: ["Services"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Services",
            dependencies: ["Core"],
            path: "Sources/Services",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Services"],
            path: "Tests/ServicesTests"
        ),
    ]
)
