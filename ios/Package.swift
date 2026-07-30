// swift-tools-version:5.3

import PackageDescription

let package = Package(
  name: "tauri-plugin-livekit-mobile",
  platforms: [
    .iOS(.v13),
    .macOS(.v10_15),
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
      url: "https://github.com/SableClient/client-sdk-swift.git",
      .revision("3f586ba2122339fa277a61f076905bd9b21da913"))
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
