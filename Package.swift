// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "swift-redux-saga",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .watchOS(.v10),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "Redux", targets: ["Redux"])
  ],
  targets: [
    .target(name: "Redux")
  ],
  swiftLanguageModes: [.v6]
)
