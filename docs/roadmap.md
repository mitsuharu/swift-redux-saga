# ロードマップ

[設計書](design.md)に沿って、1 PR = 1 目的で進めます。PR の順序は目安で、前後することがあります。完了した PR にはリンクを付けます。

ブランチ名の接頭辞: `feature/` `fix/` `docs/` `ci/` `refactor/`

## M0: 設計と計画

| # | ブランチ | 内容 |
| --- | --- | --- |
| 0-1 | `docs/design` | 設計書、ロードマップ、AGENTS.md、CI ワークフロー（**作者のレビュー・承認後にマージ**） |

## M1: Redux コア

| # | ブランチ | 内容 |
| --- | --- | --- |
| 1-1 | `feature/package-layout` | Package.swift を設計のターゲット構成に更新（tools 6.2、空のターゲットとテストターゲット） （[#2](https://github.com/mitsuharu/swift-redux-saga/pull/2)） |
| 1-2 | `feature/reducer` | `Reducer`、`combine`、`scope`、`ReducerBuilder` + テスト （[#3](https://github.com/mitsuharu/swift-redux-saga/pull/3)） |
| 1-3 | `feature/store` | `@MainActor @Observable Store`、`dispatch`、再入検出 + テスト （[#4](https://github.com/mitsuharu/swift-redux-saga/pull/4)） |
| 1-4 | `feature/middleware` | `Middleware` プロトコル、`MiddlewareAPI`、ミドルウェアチェーン + テスト （[#5](https://github.com/mitsuharu/swift-redux-saga/pull/5)） |
| 1-5 | `feature/keypath-observation` | キーパス単位の Observation 追跡（設計書 5.4）+ テスト （[#6](https://github.com/mitsuharu/swift-redux-saga/pull/6)） |
| 1-6 | `feature/store-observe` | OS に依存しない購読 API（`observe` / `values`）+ テスト （[#7](https://github.com/mitsuharu/swift-redux-saga/pull/7)） |
| 1-7 | `feature/default-isolation-tests` | default MainActor isolation を有効にしたテストターゲット （[#8](https://github.com/mitsuharu/swift-redux-saga/pull/8)） |

## M2: Saga コア

| # | ブランチ | 内容 |
| --- | --- | --- |
| 2-1 | `feature/locked` | 内部の排他制御 `Locked<Value>`（Darwin / Linux）+ テスト （[#9](https://github.com/mitsuharu/swift-redux-saga/pull/9)） |
| 2-2 | `feature/action-pattern` | `ActionPattern`（型による判定、パターンマッチ）+ テスト （[#11](https://github.com/mitsuharu/swift-redux-saga/pull/11)） |
| 2-3 | `feature/saga-runtime` | `SagaHost`、`SagaRuntime`、`ActionMulticaster`、`Saga` / `SagaContext` / `SagaTask`、`take` / `put` / `select` / `call` / `join` + テスト（骨格だけではテストできないため 2-4 と統合） （[#12](https://github.com/mitsuharu/swift-redux-saga/pull/12)） |
| 2-5 | `feature/saga-fork` | `fork` / `spawn` / `SagaTask.cancel` / `join` / `isCancelled`、キャンセル伝播 + テスト （[#13](https://github.com/mitsuharu/swift-redux-saga/pull/13)） |
| 2-6 | `feature/saga-errors` | エラー伝播、`onError`、`SagaMonitor` + テスト （[#14](https://github.com/mitsuharu/swift-redux-saga/pull/14)） |
| 2-7 | `feature/saga-testing` | `SagaTesting`: `TestClock`、`SagaTester`、`settle()`、`delay`（3-1 を統合）+ テスト （[#15](https://github.com/mitsuharu/swift-redux-saga/pull/15)） |
| 2-8 | `feature/saga-middleware` | `ReduxSaga`: `SagaMiddleware`、Host の実装 + テスト （[#16](https://github.com/mitsuharu/swift-redux-saga/pull/16)） |

## M3: Saga ヘルパー

| # | ブランチ | 内容 |
| --- | --- | --- |
| 3-1 | `feature/saga-delay` | `delay`（Clock 注入）+ テスト → 2-7 に統合 |
| 3-2 | `feature/saga-take-helpers` | `takeEvery` / `takeLatest` / `takeLeading` + テスト （[#17](https://github.com/mitsuharu/swift-redux-saga/pull/17)） |
| 3-3 | `feature/saga-debounce-throttle` | `debounce` / `throttle` + テスト （[#18](https://github.com/mitsuharu/swift-redux-saga/pull/18)） |
| 3-4 | `feature/saga-all-race` | `all` / `race`（敗者のキャンセル）+ テスト （[#19](https://github.com/mitsuharu/swift-redux-saga/pull/19)） |

## M4: Saga チャネル

| # | ブランチ | 内容 |
| --- | --- | --- |
| 4-1 | `feature/saga-channels` | `SagaChannel`、`actionChannel`（バッファ方式の指定）、`eventChannel`（購読関数版、AsyncSequence 版）+ テスト（4-2 を統合） （[#20](https://github.com/mitsuharu/swift-redux-saga/pull/20)） |

## M5: Redux Toolkit 相当

| # | ブランチ | 内容 |
| --- | --- | --- |
| 5-1 | `feature/slice` | `Slice` プロトコル + テスト （[#22](https://github.com/mitsuharu/swift-redux-saga/pull/22)） |
| 5-2 | `feature/store-builder` | `configureStore` 相当の result builder 初期化子 + テスト （[#23](https://github.com/mitsuharu/swift-redux-saga/pull/23)） |
| 5-3 | `feature/selector` | `createSelector`（メモ化）+ テスト （[#24](https://github.com/mitsuharu/swift-redux-saga/pull/24)） |
| 5-4 | `feature/entity-adapter` | `EntityState` / `EntityAdapter` + テスト （[#25](https://github.com/mitsuharu/swift-redux-saga/pull/25)） |
| 5-5 | `feature/test-store` | `ReduxTesting`: `TestStore` + テスト （[#26](https://github.com/mitsuharu/swift-redux-saga/pull/26)） |

## M6: SwiftUI / UIKit 連携

| # | ブランチ | 内容 |
| --- | --- | --- |
| 6-1 | `feature/swiftui-helpers` | `ReduxSwiftUI`: Environment、`binding` + テスト （[#27](https://github.com/mitsuharu/swift-redux-saga/pull/27)） |
| 6-2 | `feature/uikit-helpers` | `ReduxUIKit`: 購読トークンの寿命管理など + テスト （[#28](https://github.com/mitsuharu/swift-redux-saga/pull/28)） |
| 6-3 | `ci/ios-simulator-tests` | CI に iOS シミュレータでのテストを追加（必要なら） |

## M7: Example

| # | ブランチ | 内容 |
| --- | --- | --- |
| 7-1 | `feature/example-domain` | `Examples/` のローカルパッケージ（`Domain` / `AppFeature`）+ テスト （[#29](https://github.com/mitsuharu/swift-redux-saga/pull/29)） |
| 7-2 | `feature/example-swiftui` | SwiftUI / UIKit サンプルアプリ（`Examples.xcodeproj`）と CI でのビルド（7-3、7-4 を統合） （[#30](https://github.com/mitsuharu/swift-redux-saga/pull/30)） |

## M8: マクロ

| # | ブランチ | 内容 |
| --- | --- | --- |
| 8-1 | `feature/macros` | `ReduxMacros`（swift-syntax）、`@ActionCases`、`@Slice`、キーパス版の `ActionPattern.case` / `Reducer.scope` / `slice` + テスト、Example への適用（8-2、8-3 を統合） （[#32](https://github.com/mitsuharu/swift-redux-saga/pull/32)） |

## M9: ドキュメント整備

| # | ブランチ | 内容 |
| --- | --- | --- |
| 9-1 | `docs/readme` | README（使い方、redux-saga とのテスト方法の違い、default isolation の注意）、DocC カタログ、ReSwift-Saga からの移行ガイド（9-2、9-3 を統合） （[#31](https://github.com/mitsuharu/swift-redux-saga/pull/31)） |
