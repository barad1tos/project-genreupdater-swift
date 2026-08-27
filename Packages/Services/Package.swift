// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Services",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Services", targets: ["Services"]),
        .executable(name: "StoreFixtureGenerator", targets: ["StoreFixtureGenerator"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(
            url: "https://github.com/apple/swift-collections.git",
            exact: "1.2.1"
        ),
    ],
    targets: [
        .target(
            name: "Services",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HashTreeCollections", package: "swift-collections"),
            ],
            path: "Sources/Services",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "StoreFixtureGenerator",
            dependencies: ["Services"],
            path: "Sources/StoreFixtureGenerator"
        ),
        .testTarget(
            name: "ServicesTests",
            dependencies: ["Core", "Services", "StoreFixtureGenerator"],
            path: "Tests/ServicesTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
