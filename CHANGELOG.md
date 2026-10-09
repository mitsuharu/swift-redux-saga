# 変更履歴

このプロジェクトの変更を記録します。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。1.0.0 までは、マイナーバージョンでも公開 API が変わることがあります。

## [Unreleased]

### 追加

- 子の State・Action で書いた Saga を、子の型のまま親に接続する `SagaRuntime.run(_:state:action:embed:)` / `SagaMiddleware.run(_:state:action:embed:)` / `SagaContext.fork(_:state:action:embed:)`（Reducer の `scope` の Saga 版）
- `TestStore` / `SagaTester` に、Saga が止まるのを待たずに送る `dispatch` と、Action が届くまで待つ `receive(_:timeout:)` を追加。応答を手動で返すスタブで、通信が重なる場面（検索語の連続した変更、結果の到着順の逆転など）を検証できる
- `Identifiable` の配列の要素を ID で読み書きする添字 `[id:]`（`Redux`）。添字のキーパス（`\.todos[index]`）で読んだ要素を削除すると停止するため、一覧の要素は ID で読む
- Optional の値の `Binding` を作る `store.binding(_:default:send:)`（`ReduxSwiftUI`）

### ドキュメント

- README に Saga の寿命（アプリ・ログイン中・画面の表示中）に合わせた起動と停止の書き方を追加
- Example を、ログイン（`AuthFeature`）と ToDo（`TodoFeature`）の 2 つの機能を親に接続する構成にした。ToDo の Saga はログイン中だけ動く
- README に Saga のエラー処理の節を追加（ワーカーのエラーで、すべての Saga が止まることと、その避け方）

### 修正

- `eventChannel(from:)`: シーケンスがエラーで終わっても、受け取り側では正常終了になっていた。溜まった値の後にそのエラーを投げる。購読関数版も `finish(throwing:)` でエラーを伝えられる（`finish` の型は `EventChannelFinish`。`finish()` の呼び方は変わらない）
- `call`: キャンセルされた後に関数が `CancellationError` 以外のエラー（`URLError(.cancelled)` など）を投げると、そのまま投げていた。ワーカーの一般的な `catch` が古い失敗を Action にし、新しい結果を上書きし得た。キャンセル後は `CancellationError` を投げる
- `EntityAdapter.updateOne` / `updateMany`: 更新で ID をすでにある ID に変えると、`ids` に同じ ID が 2 つ並んだ。すでにあるエンティティを置き換える（Redux Toolkit と同じ）
- `observe` / `ObservationToken.observe`: 購読を解除（`cancel()` / トークンの解放）しても、監視している値が次に変わるまで、ハンドラが捕捉したオブジェクトを保持していた。解除した時点で手放す
- `call`: キャンセルに応じない関数が、キャンセルされた後に値を返すと、その値を返していた。`takeLatest` で止めた古い結果が新しい結果を上書きし得た。戻った後もキャンセルを確認する
- `all` / `race`: 処理の中で fork した子の失敗を、呼び出し元で catch できず、ルート Saga まで止まっていた
- `race`: 最初に終わった処理がキャンセルで終わると、全要素が `nil` のタプルを正常に返していた。`CancellationError` を投げる
- `run` の直後（Saga が動き出す前）に dispatch した Action が Saga に届かず、黙って失われていた。起動した Saga が最初の Effect に達するまで溜めて、後から届ける
- 実時間の時計で `delay` している Saga があると、`waitUntilIdle()` が戻らない不具合を修正
- 永続化の保存が重なったとき（`flush()` の最中に State が変わった場合を含む）、古い State が後から書かれて残り得た不具合を修正（`PersistenceMiddleware`）

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
