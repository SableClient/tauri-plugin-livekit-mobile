// swift-tools-version:5.9
//
// Host-side wire-contract harness for the iOS LiveKit bridge.
//
// The plugin's Swift sources live in the Xcode project at
// `ios/tauri-plugin-livekit-mobile/` (the Xcode framework template, not an
// SPM plugin). This SPM package exists only to compile and run the bridge's
// host unit tests against those same sources without a second copy: the
// `tauri-plugin-livekit-mobile` target below points at the plugin folder
// through the `tauri-plugin-livekit-mobile` symlink, because SwiftPM forbids
// a target `path:` from escaping the package root.
//
// The Tauri Swift API is the local package at `../.tauri/tauri-api`
// (populated by the build); the LiveKit product is the same Sable fork pinned
// in the Xcode project, at revision
// `3f586ba2122339fa277a61f076905bd9b21da913`.
//
// Note: the bridge sources `import UIKit`, so this package builds for the iOS
// Simulator and the tests run there (see the README / CI). `swift build` /
// `swift test` from this directory build for the iOS Simulator with
// `--sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple
// arm64-apple-ios17.0-simulator`; test execution itself requires
// `xcodebuild test` against this package on a booted simulator because
// SwiftPM's test runner cannot launch iOS-Simulator bundles on the macOS
// host.

import PackageDescription

let package = Package(
  name: "ios-tests",
  platforms: [
    .iOS(.v14),
  ],
  products: [
    .library(name: "tauri-plugin-livekit-mobile", type: .static, targets: ["tauri-plugin-livekit-mobile"])
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
      path: "tauri-plugin-livekit-mobile"),
    .testTarget(
      name: "LivekitMobilePluginTests",
      dependencies: [
        .byName(name: "tauri-plugin-livekit-mobile")
      ],
      path: "Tests")
  ]
)
