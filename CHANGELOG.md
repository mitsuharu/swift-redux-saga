# 変更履歴

このプロジェクトの変更を記録します。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。1.0.0 までは、マイナーバージョンでも公開 API が変わることがあります。

## [Unreleased]

### 修正

- 実時間の時計で `delay` している Saga があると、`waitUntilIdle()` が戻らない不具合を修正

## [0.1.0] - 2026-10-09

最初のリリースです。

### Redux（`Redux`）

- `Store`（`@MainActor`、`Observable`）。読んだプロパティだけを追跡するキーパス単位の Observation、dispatch 中の dispatch はキューで後から処理
- `Reducer`（`inout`）と合成（`combine` / `scope` / `ReducerBuilder`）、`Slice`（`createSlice` 相当）
- `Middleware` / `MiddlewareAPI`、result builder で Store を作る初期化子（`configureStore` 相当）
- `createSelector`（メモ化）、`EntityState` / `EntityAdapter`（`createEntityAdapter` 相当）
- OS に依存しない購読 API（`observe` / `values` / `ObservationToken.observe`）
- 入力欄の Binding（`@BindableState` / `BindingAction` / `BindableAction`）
- ネストしたプロパティ単位の追跡（`TrackedState`）
- `LoggingMiddleware`（`os.Logger`、既定でデバッグビルドのみ）

### Saga（`Saga` / `ReduxSaga`）

- 構造化並行性で実装した Saga ランタイム。`SagaHost` プロトコル越しに動き、Redux に依存しない
- Effect: `take` / `put` / `select` / `call`（任意の async 関数）/ `fork`（attached）/ `spawn`（detached）/ `cancel` / `join` / `delay`
- ヘルパー: `takeEvery` / `takeLatest` / `takeLeading` / `debounce` / `throttle`、組み合わせ: `all` / `race`
- チャネル: `actionChannel` / `eventChannel`（複数の Saga から読める）
- `ActionPattern`（型による判定と、enum の case からの値の取り出し）
- エラー処理（`SagaError` / `onError`）と `SagaMonitor`
- `SagaMiddleware`（Redux の Store に Saga を載せる）

### マクロ（`ReduxMacros`）

- `@ActionCases`、`@Slice`、`@TrackedState`

### 永続化（`ReduxPersistence`）

- `Persistence`（バージョンと移行）、`PersistenceMiddleware`、保存先（`UserDefaultsStorage` / `FileStorage` / `InMemoryStorage`）

### UI（`ReduxSwiftUI` / `ReduxUIKit`）

- SwiftUI: `store.binding`、`.store(_:)`
- UIKit: `ObservationToken.retained(by:)`、`store.action`

### テスト支援（`SagaTesting` / `ReduxTesting`）

- `TestClock`、`SagaTester`、`TestStore`。実時間ではなく「すべての Saga が Effect で止まったか」で待ち合わせる

[0.1.0]: https://github.com/mitsuharu/swift-redux-saga/releases/tag/0.1.0
