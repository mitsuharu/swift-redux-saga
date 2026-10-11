# 変更履歴

このプロジェクトの変更を記録します。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。1.0.0 までは、マイナーバージョンでも公開 API が変わることがあります。

## [Unreleased]

### ドキュメント

- [State の永続化](https://github.com/mitsuharu/swift-redux-saga/blob/main/docs/persistence.md): 保存する部分の選び方、保存先、保存のタイミング、データの削除、保存形式の変更、テストの書き方

## [0.2.0] - 2026-10-11

### 追加

- SwiftUI で、Store の型を書かずに値を読む `@SelectState` と、Action を送る `@DispatchAction`（React Redux の `useSelector` / `useDispatch` に当たる、`ReduxSwiftUI`）。`@SelectState` は読んだ値（セレクタの計算結果を含む）が変わったときだけ再描画する
- 識別子を付けて Store を Environment に入れる `.store(_:id:)` と `StoreID`。`@SelectState` / `@DispatchAction` の `store:` で指定して、入れ子にした同じ型の Store を区別できる

### ドキュメント

- [Saga の Effect](https://github.com/mitsuharu/swift-redux-saga/blob/0.2.0/docs/saga-effects.md): redux-saga の Effect との対応と、それぞれの使い方
- README: Saga の処理を別の関数として定義して渡す書き方、`@SelectState` / `@DispatchAction` の使い方（入れ子の Store で使われる Store の決まり方、セレクタの再計算のコストとメモ化したセレクタの使い方）

## [0.1.0] - 2026-10-11

最初のリリースです。

### Redux（`Redux`）

- `Store`（`@MainActor`、`Observable`）。読んだプロパティだけを追跡するキーパス単位の Observation、dispatch 中の dispatch はキューで後から処理
- `Store.scope(state:action:)`（State と Action の一部だけを扱う Store。機能ごとのモジュールの View や ViewModel 向け）
- `Reducer`（`inout`）と合成（`combine` / `scope` / `ReducerBuilder`）、`Slice`（`createSlice` 相当）
- `Middleware` / `MiddlewareAPI`、result builder で Store を作る初期化子（`configureStore` 相当）
- `createSelector`（メモ化）、`EntityState` / `EntityAdapter`（`createEntityAdapter` 相当）、`Identifiable` の配列を ID で読み書きする添字 `[id:]`
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
- `SagaMiddleware`（Redux の Store に Saga を載せる）。起動直後に dispatch した Action も取りこぼさない
- 子の State・Action で書いた Saga を、子の型のまま親に接続する（`run(_:state:action:embed:)` / `ctx.fork(_:state:action:embed:)`）

### マクロ（`ReduxMacros`）

- `@ActionCases`、`@Slice`、`@TrackedState`

### 永続化（`ReduxPersistence`）

- `Persistence`（バージョンと移行）、`PersistenceMiddleware`（保存を待っている State を捨てて消す `clear()`、すぐに保存する `flush()`）、保存先（`UserDefaultsStorage` / `FileStorage` / `InMemoryStorage`）

### UI（`ReduxSwiftUI` / `ReduxUIKit`）

- SwiftUI: `store.binding`（Optional の値には `default:`）、`.store(_:)`
- UIKit: `ObservationToken.retained(by:)`、`store.action`

### テスト支援（`SagaTesting` / `ReduxTesting`）

- `TestClock`、`SagaTester`、`TestStore`。実時間ではなく「すべての Saga が Effect で止まったか」で待ち合わせる
- 通信が重なる場面のテスト（待たずに送る `dispatch` と、届くまで待つ `receive(_:timeout:)`）

[Unreleased]: https://github.com/mitsuharu/swift-redux-saga/compare/0.2.0...HEAD
[0.2.0]: https://github.com/mitsuharu/swift-redux-saga/releases/tag/0.2.0
[0.1.0]: https://github.com/mitsuharu/swift-redux-saga/releases/tag/0.1.0
