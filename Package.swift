// swift-tools-version: 6.2
import CompilerPluginSupport
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
  // プロダクトは用途ごとに、それだけで import できるよう依存するターゲットも含める
  // （例: ReduxSaga だけを追加すれば Redux と Saga も使える）。
  products: [
    .library(name: "Redux", targets: ["Redux"]),
    .library(name: "Saga", targets: ["Saga"]),
    .library(name: "ReduxSaga", targets: ["Redux", "Saga", "ReduxSaga"]),
    .library(name: "ReduxSwiftUI", targets: ["Redux", "ReduxSwiftUI"]),
    .library(name: "ReduxUIKit", targets: ["Redux", "ReduxUIKit"]),
    .library(name: "ReduxMacros", targets: ["Redux", "ReduxMacros"]),
    .library(name: "ReduxPersistence", targets: ["Redux", "ReduxPersistence"]),
    .library(name: "SagaTesting", targets: ["Saga", "SagaTesting"]),
    .library(
      name: "ReduxTesting", targets: ["Redux", "Saga", "ReduxSaga", "SagaTesting", "ReduxTesting"]),
  ],
  dependencies: [
    // マクロ（ReduxMacros）の実装にだけ使う。範囲を広く取るのは、利用者の Xcode / ツールチェーンに
    // 合った版（Xcode に同梱のビルド済み swift-syntax）を選べるようにするため。
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"605.0.0")
  ],
  targets: [
    // ライブラリ内部で共有する部品。プロダクトとして公開せず、`package` アクセスで使う。
    .target(name: "InternalPrimitives"),
    .target(name: "Redux", dependencies: ["InternalPrimitives"]),
    .target(name: "Saga", dependencies: ["InternalPrimitives"]),
    .target(name: "ReduxSaga", dependencies: ["Redux", "Saga", "InternalPrimitives"]),
    .target(name: "ReduxSwiftUI", dependencies: ["Redux"]),
    .target(name: "ReduxUIKit", dependencies: ["Redux"]),
    .target(name: "SagaTesting", dependencies: ["Saga", "InternalPrimitives"]),
    .target(
      name: "ReduxTesting",
      dependencies: ["Redux", "ReduxSaga", "SagaTesting", "InternalPrimitives"]
    ),
    .macro(
      name: "ReduxMacrosPlugin",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(name: "ReduxMacros", dependencies: ["Redux", "ReduxMacrosPlugin"]),
    // State の永続化。Foundation（JSON / ファイル / UserDefaults）を使うので、Redux 本体から分ける。
    .target(name: "ReduxPersistence", dependencies: ["Redux", "InternalPrimitives"]),

    .testTarget(name: "InternalPrimitivesTests", dependencies: ["InternalPrimitives"]),
    .testTarget(name: "ReduxTests", dependencies: ["Redux", "InternalPrimitives"]),
    .testTarget(name: "SagaTests", dependencies: ["Saga", "SagaTesting", "InternalPrimitives"]),
    .testTarget(name: "ReduxSagaTests", dependencies: ["ReduxSaga", "SagaTesting"]),
    .testTarget(name: "ReduxSwiftUITests", dependencies: ["ReduxSwiftUI", "InternalPrimitives"]),
    .testTarget(name: "ReduxUIKitTests", dependencies: ["ReduxUIKit"]),
    .testTarget(
      name: "ReduxPersistenceTests",
      dependencies: ["ReduxPersistence", "SagaTesting", "InternalPrimitives"]
    ),
    .testTarget(
      name: "ReduxTestingTests",
      dependencies: ["ReduxTesting", "ReduxSaga", "Saga", "InternalPrimitives"]),
    .testTarget(
      name: "ReduxMacrosTests",
      dependencies: [
        "ReduxMacros",
        "ReduxMacrosPlugin",
        "Redux",
        "Saga",
        "SagaTesting",
        "InternalPrimitives",
        .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
      ]
    ),
    // アプリが default MainActor isolation を有効にしていても使えることを確かめるテスト。
    .testTarget(
      name: "DefaultIsolationTests",
      dependencies: ["Redux", "ReduxSaga", "SagaTesting", "ReduxMacros"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
  ],
  swiftLanguageModes: [.v6]
)

// CI では、このパッケージのターゲットの警告をエラーにする（「警告ゼロ」を保つため）。
// - コマンドラインの -warnings-as-errors を使わないのは、依存の swift-syntax にも効き、
//   swift-syntax 側の -suppress-warnings と衝突してビルドできないため。
// - 常に有効にしないのは、Xcode がローカルパッケージを依存としてビルドするときに -suppress-warnings を付け、
//   同じく衝突するため（Example のアプリのビルドで発生）。
if Context.environment["SWIFT_REDUX_SAGA_WARNINGS_AS_ERRORS"] == "1" {
  for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
  }
}
