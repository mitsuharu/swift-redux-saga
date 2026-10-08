// swift-tools-version: 6.2
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
    .library(name: "Redux", targets: ["Redux"]),
    .library(name: "Saga", targets: ["Saga"]),
    .library(name: "ReduxSaga", targets: ["ReduxSaga"]),
    .library(name: "ReduxSwiftUI", targets: ["ReduxSwiftUI"]),
    .library(name: "ReduxUIKit", targets: ["ReduxUIKit"]),
    .library(name: "SagaTesting", targets: ["SagaTesting"]),
    .library(name: "ReduxTesting", targets: ["ReduxTesting"]),
  ],
  targets: [
    // ライブラリ内部で共有する部品。プロダクトとして公開せず、`package` アクセスで使う。
    .target(name: "InternalPrimitives"),
    .target(name: "Redux", dependencies: ["InternalPrimitives"]),
    .target(name: "Saga", dependencies: ["InternalPrimitives"]),
    .target(name: "ReduxSaga", dependencies: ["Redux", "Saga"]),
    .target(name: "ReduxSwiftUI", dependencies: ["Redux"]),
    .target(name: "ReduxUIKit", dependencies: ["Redux"]),
    .target(name: "SagaTesting", dependencies: ["Saga", "InternalPrimitives"]),
    .target(name: "ReduxTesting", dependencies: ["Redux"]),

    .testTarget(name: "InternalPrimitivesTests", dependencies: ["InternalPrimitives"]),
    .testTarget(name: "ReduxTests", dependencies: ["Redux"]),
    .testTarget(name: "SagaTests", dependencies: ["Saga", "SagaTesting", "InternalPrimitives"]),
    .testTarget(name: "ReduxSagaTests", dependencies: ["ReduxSaga", "SagaTesting"]),
    .testTarget(name: "ReduxSwiftUITests", dependencies: ["ReduxSwiftUI"]),
    .testTarget(name: "ReduxUIKitTests", dependencies: ["ReduxUIKit"]),
    .testTarget(name: "ReduxTestingTests", dependencies: ["ReduxTesting"]),
    // アプリが default MainActor isolation を有効にしていても使えることを確かめるテスト。
    .testTarget(
      name: "DefaultIsolationTests",
      dependencies: ["Redux"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
  ],
  swiftLanguageModes: [.v6]
)
