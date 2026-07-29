// swift-tools-version:5.3

import PackageDescription

let package = Package(
  name: "tauri-plugin-call-lifecycle",
  platforms: [
    .iOS(.v13),
  ],
  products: [
    .library(
      name: "tauri-plugin-call-lifecycle",
      type: .static,
      targets: ["tauri-plugin-call-lifecycle"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-call-lifecycle",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources")
  ]
)
