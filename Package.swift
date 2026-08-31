// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "WindowBurn",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "WindowBurnCore", targets: ["WindowBurnCore"]),
    .executable(name: "WindowBurn", targets: ["WindowBurn"]),
  ],
  targets: [
    .target(name: "WindowBurnCore"),
    .executableTarget(
      name: "WindowBurn",
      dependencies: ["WindowBurnCore"],
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Carbon"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("OSLog"),
        .linkedFramework("ScreenCaptureKit"),
      ]
    ),
    .testTarget(name: "WindowBurnCoreTests", dependencies: ["WindowBurnCore"]),
  ]
)
