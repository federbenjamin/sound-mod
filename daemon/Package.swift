// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "stemmix",
  platforms: [.macOS("14.2")],
  targets: [
    .executableTarget(name: "stemmix", path: "Sources/stemmix"),
    .testTarget(name: "stemmixTests", dependencies: ["stemmix"], path: "Tests/stemmixTests"),
  ]
)
