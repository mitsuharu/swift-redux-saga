// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// マニフェストはバンドルの直下に名前を変えずに置く必要があるので、加工されない .copy で入れる。
let privacyManifest: [Resource] = [.copy("PrivacyInfo.xcprivacy")]

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
    // アプリに組み込まれるターゲットには、プライバシーマニフェスト（PrivacyInfo.xcprivacy）を入れる。
    // 情報の収集や追跡をしないターゲットは空の宣言だが、App Store の審査で確認できるよう、すべてに置く
    // （「収集していない」ことを明示するため）。テスト支援のターゲットはアプリに入らないので置かない。
    // ライブラリ内部で共有する部品。プロダクトとして公開せず、`package` アクセスで使う。
    .target(name: "InternalPrimitives", resources: privacyManifest),
    .target(name: "Redux", dependencies: ["InternalPrimitives"], resources: privacyManifest),
    .target(name: "Saga", dependencies: ["InternalPrimitives"], resources: privacyManifest),
    .target(
      name: "ReduxSaga", dependencies: ["Redux", "Saga", "InternalPrimitives"],
      resources: privacyManifest),
    .target(name: "ReduxSwiftUI", dependencies: ["Redux"], resources: privacyManifest),
    .target(name: "ReduxUIKit", dependencies: ["Redux"], resources: privacyManifest),
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
    .target(
      name: "ReduxMacros", dependencies: ["Redux", "ReduxMacrosPlugin"], resources: privacyManifest),
    // State の永続化。Foundation（JSON / ファイル / UserDefaults）を使うので、Redux 本体から分ける。
    // UserDefaultsStorage が UserDefaults（理由の申告が必要な API）を使うので、マニフェストで理由を申告する。
    .target(
      name: "ReduxPersistence", dependencies: ["Redux", "InternalPrimitives"],
      resources: privacyManifest),

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
