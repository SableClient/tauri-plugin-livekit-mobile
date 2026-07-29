// swift-tools-version:5.3

import PackageDescription

let package = Package(
  name: "tauri-plugin-livekit-mobile",
  platforms: [
    .iOS(.v13),
  ],
  products: [
    .library(
      name: "tauri-plugin-livekit-mobile",
      type: .static,
      targets: ["tauri-plugin-livekit-mobile"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api"),
    .package(
      name: "LiveKit",
      url: "https://github.com/livekit/client-sdk-swift.git",
      .upToNextMajor(from: "2.15.3"))
  ],
  targets: [
    .target(
      name: "tauri-plugin-livekit-mobile",
      dependencies: [
        .byName(name: "Tauri"),
        .product(name: "LiveKit", package: "LiveKit")
      ],
      path: "Sources"),
    .testTarget(
      name: "LivekitMobilePluginTests",
      dependencies: [
        .byName(name: "tauri-plugin-livekit-mobile")
      ],
      path: "Tests")
  ]
)
