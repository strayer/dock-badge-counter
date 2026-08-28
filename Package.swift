// swift-tools-version: 5.9
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
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
  ],
  targets: [
    .executableTarget(
      name: "dock-badge-counter",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "TOMLKit", package: "TOMLKit"),
      ],
      path: "Sources"
    ),
    .testTarget(
      name: "dock-badge-counterTests",
      dependencies: ["dock-badge-counter"],
      path: "Tests"
    ),
  ]
)
