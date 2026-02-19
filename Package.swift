// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "swift-tracing-logflare",
  platforms: [
    .iOS(.v13),
    .macOS(.v10_15),
    .tvOS(.v13),
    .watchOS(.v6),
  ],
  products: [
    .library(
      name: "TracingLogflare",
      targets: ["TracingLogflare"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/grdsdev/swift-tracing.git", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "TracingLogflare",
      dependencies: [
        .product(name: "Tracing", package: "swift-tracing"),
      ]
    ),
    .testTarget(
      name: "TracingLogflareTests",
      dependencies: ["TracingLogflare"]
    ),
  ]
)
