// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "dock-badge-counter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "dock-badge-counter",
            targets: ["dock-badge-counter"]
        )
    ],
    targets: [
        .executableTarget(
            name: "dock-badge-counter",
            path: "Sources",
            swiftSettings: [
                .unsafeFlags([
                    "-O",
                    "-whole-module-optimization"
                ], .when(configuration: .release))
            ]
        )
    ]
)
