// swift-tools-version: 6.2
import PackageDescription

// サンプルアプリのロジック。ロックインを避ける推奨構成を示す。
// - Domain: 本ライブラリに依存しない（Model / Repository / UseCase）
// - AppFeature: Domain と本ライブラリに依存する（State / Action / Reducer / Saga）
// - アプリ本体（Examples.xcodeproj）: View と Store の組み立て
let package = Package(
  name: "ExampleKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "Domain", targets: ["Domain"]),
    .library(name: "AppFeature", targets: ["AppFeature"]),
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(name: "Domain"),
    .target(
      name: "AppFeature",
      dependencies: [
        "Domain",
        .product(name: "Redux", package: "swift-redux-saga"),
        .product(name: "Saga", package: "swift-redux-saga"),
        .product(name: "ReduxSaga", package: "swift-redux-saga"),
      ]
    ),
    .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    .testTarget(
      name: "AppFeatureTests",
      dependencies: [
        "AppFeature",
        .product(name: "ReduxTesting", package: "swift-redux-saga"),
        .product(name: "SagaTesting", package: "swift-redux-saga"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
