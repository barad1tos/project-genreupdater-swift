// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignUI", targets: ["DesignUI"])
    ],
    targets: [
        .target(name: "DesignUI"),
        .testTarget(name: "DesignUITests", dependencies: ["DesignUI"]),
    ]
)
