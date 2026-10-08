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
| 1-1 | `feature/package-layout` | Package.swift を設計のターゲット構成に更新（tools 6.2、空のターゲットとテストターゲット） |
| 1-2 | `feature/reducer` | `Reducer`、`combine`、`scope`、`ReducerBuilder` + テスト |
| 1-3 | `feature/store` | `@MainActor @Observable Store`、`dispatch`、再入検出 + テスト |
| 1-4 | `feature/middleware` | `Middleware` プロトコル、`MiddlewareAPI`、ミドルウェアチェーン + テスト |
| 1-5 | `feature/keypath-observation` | キーパス単位の Observation 追跡（設計書 5.4）+ テスト |
| 1-6 | `feature/store-observe` | OS に依存しない購読 API（`observe` / `values`）+ テスト |
| 1-7 | `feature/default-isolation-tests` | default MainActor isolation を有効にしたテストターゲット |

## M2: Saga コア

| # | ブランチ | 内容 |
| --- | --- | --- |
| 2-1 | `feature/locked` | 内部の排他制御 `Locked<Value>`（Darwin / Linux）+ テスト |
| 2-2 | `feature/action-pattern` | `ActionPattern`（型による判定、パターンマッチ）+ テスト |
| 2-3 | `feature/saga-runtime` | `SagaHost`、`SagaRuntime`、`ActionMulticaster`、`Saga` / `SagaContext` の骨格 + テスト |
| 2-4 | `feature/saga-basic-effects` | `take` / `put` / `select` / `call` + テスト |
| 2-5 | `feature/saga-fork` | `fork` / `spawn` / `SagaTask.cancel` / `join` / `isCancelled`、キャンセル伝播 + テスト |
| 2-6 | `feature/saga-errors` | エラー伝播、`onError`、`SagaMonitor` + テスト |
| 2-7 | `feature/saga-testing` | `SagaTesting`: `TestClock`、`SagaTester`、`settle()` + テスト |
| 2-8 | `feature/saga-middleware` | `ReduxSaga`: `SagaMiddleware`、Host の実装 + テスト |

## M3: Saga ヘルパー

| # | ブランチ | 内容 |
| --- | --- | --- |
| 3-1 | `feature/saga-delay` | `delay`（Clock 注入）+ テスト |
| 3-2 | `feature/saga-take-helpers` | `takeEvery` / `takeLatest` / `takeLeading` + テスト |
| 3-3 | `feature/saga-debounce-throttle` | `debounce` / `throttle` + テスト |
| 3-4 | `feature/saga-all-race` | `all` / `race`（敗者のキャンセル）+ テスト |

## M4: Saga チャネル

| # | ブランチ | 内容 |
| --- | --- | --- |
| 4-1 | `feature/action-channel` | `actionChannel`（バッファ方式の指定）+ テスト |
| 4-2 | `feature/event-channel` | `eventChannel`（購読関数版、AsyncSequence 版）+ テスト |

## M5: Redux Toolkit 相当

| # | ブランチ | 内容 |
| --- | --- | --- |
| 5-1 | `feature/slice` | `Slice` プロトコル + テスト |
| 5-2 | `feature/store-builder` | `configureStore` 相当の result builder 初期化子 + テスト |
| 5-3 | `feature/selector` | `createSelector`（メモ化）+ テスト |
| 5-4 | `feature/entity-adapter` | `EntityState` / `EntityAdapter` + テスト |
| 5-5 | `feature/test-store` | `ReduxTesting`: `TestStore` + テスト |

## M6: SwiftUI / UIKit 連携

| # | ブランチ | 内容 |
| --- | --- | --- |
| 6-1 | `feature/swiftui-helpers` | `ReduxSwiftUI`: Environment、`binding` + テスト |
| 6-2 | `feature/uikit-helpers` | `ReduxUIKit`: 購読トークンの寿命管理など + テスト |
| 6-3 | `ci/ios-simulator-tests` | CI に iOS シミュレータでのテストを追加（必要なら） |

## M7: Example

| # | ブランチ | 内容 |
| --- | --- | --- |
| 7-1 | `feature/example-domain` | `Examples/` のローカルパッケージ（`Domain` / `AppFeature`）+ テスト |
| 7-2 | `feature/example-swiftui` | SwiftUI サンプルアプリ |
| 7-3 | `feature/example-uikit` | UIKit サンプルアプリ |
| 7-4 | `ci/example-build` | CI で Example をビルド |

## M8: マクロ（任意）

| # | ブランチ | 内容 |
| --- | --- | --- |
| 8-1 | `feature/macros-target` | `ReduxMacros` ターゲット（swift-syntax）の追加 |
| 8-2 | `feature/case-pattern-macro` | enum の case から `ActionPattern` を生成するマクロ + テスト |
| 8-3 | `feature/slice-macro` | `@Slice` マクロ + テスト |

## M9: ドキュメント整備

| # | ブランチ | 内容 |
| --- | --- | --- |
| 9-1 | `docs/readme` | README（使い方、redux-saga とのテスト方法の違い、default isolation の注意） |
| 9-2 | `docs/docc` | 各ターゲットの DocC カタログ |
| 9-3 | `docs/migration` | ReSwift-Saga からの移行ガイド |
