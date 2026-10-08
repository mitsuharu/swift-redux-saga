# swift-redux-saga

Swift 6 で書かれた Redux（[Redux Toolkit](https://redux-toolkit.js.org/) を参考にした実装）と、その上で動く [Redux Saga](https://redux-saga.js.org/) の Swift Package です。

> [!WARNING]
> 開発中です。1.0 まで API は変わることがあります。

## 特徴

- **Swift 6 言語モード**（strict concurrency）で警告ゼロ。Store は `@MainActor`、Saga はメインアクター外で動きます
- **外部ライブラリに依存しない**（標準ライブラリと Apple 公式フレームワークのみ）
- **構造化並行性で実装した Saga**: `fork` した子は親のタスクの子タスクになり、キャンセルは親から子へ必ず伝わります
- **ロックインを避ける設計**: ビジネスロジック（UseCase / Repository）は本ライブラリを import せずに書け、Saga は「Action → ビジネスロジック → Action」の薄い層になります
- **Observation 対応**: SwiftUI ではプロパティ単位で再描画され、UIKit の自動追跡（iOS 26 以降、iOS 18 はオプトイン）にも乗れます
- **テストしやすい**: 実時間に依存しない `TestClock` と、Saga や Store の結果を検証する `SagaTester` / `TestStore`

## 動作環境

- Swift 6.2 以降（Xcode 26 以降）
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 以降
- `Redux` / `Saga` / `ReduxSaga` / `SagaTesting` は Linux でも動きます

## インストール

`Package.swift` の `dependencies` に追加します。

```swift
dependencies: [
  .package(url: "https://github.com/mitsuharu/swift-redux-saga.git", branch: "main")
]
```

| プロダクト | 内容 |
| --- | --- |
| `Redux` | Store / Reducer / Middleware / Slice / Selector / EntityAdapter |
| `Saga` | Saga のランタイムと Effect（Redux に依存しない） |
| `ReduxSaga` | Store に Saga を載せる `SagaMiddleware` |
| `ReduxSwiftUI` / `ReduxUIKit` | SwiftUI / UIKit 用のヘルパー |
| `SagaTesting` / `ReduxTesting` | テスト支援（`TestClock` / `SagaTester` / `TestStore`） |
| `ReduxMacros` | マクロ（`@ActionCases` / `@Slice`）。使う場合だけ追加します |

## 使い方

### State・Action・reducer（Slice）

```swift
import Redux

enum Counter: Slice {
  struct State: Sendable, Equatable {
    var count = 0
    var isLoading = false
  }

  enum Action: Sendable, Equatable {
    case increment
    case fetch
    case fetched(Int)
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .increment: state.count += 1
    case .fetch: state.isLoading = true
    case .fetched(let value):
      state.isLoading = false
      state.count = value
    }
  }
}
```

reducer は `inout` で State を直接書き換える純粋関数です。複数の Slice は `Reducer.slice(_:state:action:)` で親の State にまとめられます。

### Saga

ビジネスロジックは本ライブラリに依存しない形で書きます。

```swift
// Domain（本ライブラリを import しない）
struct CounterRepository: Sendable {
  let load: @Sendable () async throws -> Int
}
```

Saga は `SagaContext` を受け取る async 関数です。redux-saga の `yield` の代わりに、`ctx` の Effect を `await` で呼びます。依存は Saga を作るときに注入します。

```swift
import Saga

struct CounterSagas: Sendable {
  let repository: CounterRepository

  var root: Saga<Counter.State, Counter.Action> {
    Saga("counter") { ctx in
      ctx.takeLatest(.action(.fetch)) { ctx, _ in
        do {
          let value = try await ctx.call(repository.load)
          await ctx.put(.fetched(value))
        } catch {
          // エラーも Action にして返す
        }
      }
    }
  }
}
```

| redux-saga | swift-redux-saga |
| --- | --- |
| `function* saga() {}` | `Saga { ctx in ... }` |
| `yield take(pattern)` | `try await ctx.take(pattern)` |
| `yield put(action)` | `await ctx.put(action)` |
| `yield select(selector)` | `await ctx.select(selector)` |
| `yield call(fn, ...args)` | `try await ctx.call(fn, args...)` |
| `yield fork(saga)` / `spawn` | `ctx.fork(saga)` / `ctx.spawn(saga)` |
| `yield cancel(task)` / `join` | `ctx.cancel(task)` / `try await ctx.join(task)` |
| `yield delay(ms)` | `try await ctx.delay(.milliseconds(ms))` |
| `takeEvery` / `takeLatest` / `takeLeading` | `ctx.takeEvery` / `ctx.takeLatest` / `ctx.takeLeading` |
| `debounce` / `throttle` | `ctx.debounce` / `ctx.throttle` |
| `all` / `race` | `try await ctx.all(...)` / `try await ctx.race(...)` |
| `actionChannel` / `eventChannel` | `ctx.actionChannel(...)` / `ctx.eventChannel(...)` |

Action の判定は `ActionPattern` で行います。enum の case から値を型付きで取り出せます。

```swift
let fetch = ActionPattern<AppAction, User.ID>.case {
  if case .user(.fetch(let id)) = $0 { id } else { nil }
}
let id = try await ctx.take(fetch)
```

### マクロ（ReduxMacros）

`@ActionCases` を enum に付けると、case ごとに関連値を取り出すプロパティが生成され、`if case ... else nil` を書かずに済みます。`@Slice` は Slice への準拠、`initialState`、`Action` への `@ActionCases` を補います。

```swift
import ReduxMacros

@Slice
enum Counter {
  struct State: Sendable, Equatable { var count = 0 }
  enum Action: Sendable, Equatable { case increment, fetch, fetched(Int) }
  static func reduce(into state: inout State, action: Action) { ... }
}

@ActionCases
enum AppAction: Sendable {
  case counter(Counter.Action)
  case user(UserAction)
}

Reducer.slice(Counter.self, state: \.counter, action: \.counter)
ctx.takeEvery(.case(\.user?.fetch)) { ctx, id in ... }
```

マクロなしでも同じことができます（`.case { if case .user(.fetch(let id)) = $0 { id } else { nil } }`）。Xcode は初めてマクロを使うときに許可を求めます。

### Store と組み立て

```swift
import Redux
import ReduxSaga

@MainActor
func makeStore() -> Store<Counter.State, Counter.Action> {
  let sagaMiddleware = SagaMiddleware<Counter.State, Counter.Action>()
  let store = Store(
    initialState: Counter.initialState,
    reducer: Counter.reducer,
    middleware: [sagaMiddleware]
  )
  sagaMiddleware.run(CounterSagas(repository: .live).root)
  return store
}
```

> [!IMPORTANT]
> redux-saga の `run` はルート Saga を最初の `take` まで同期に進めますが、Swift では async 関数を同期に進められないため、`run` の直後に dispatch した Action は、まだ待ち始めていない Saga に届かないことがあります。起動時の処理はルート Saga の中に書くか（推奨）、`await sagaMiddleware.waitUntilIdle()` で待ってから dispatch してください。

### SwiftUI

`store.count` のように State のプロパティを直接読むと、そのプロパティが変わったときだけ再描画されます。

```swift
import ReduxSwiftUI

struct CounterView: View {
  @Environment(Store<Counter.State, Counter.Action>.self) private var store

  var body: some View {
    VStack {
      Text("\(store.count)")
      Button("+1") { store.dispatch(.increment) }
      Button("Fetch") { store.dispatch(.fetch) }
        .disabled(store.isLoading)
    }
  }
}

// 親で .store(store) を付ける。入力欄は store.binding(\.text, send: { .textChanged($0) }) で作れる。
```

### UIKit

iOS 26 以降（または `UIObservationTrackingEnabled` を有効にした iOS 18 以降）は、`updateProperties()` や `viewWillLayoutSubviews()` で `store.count` を読むだけで自動で追跡されます。それ以前の OS では `observe` を使います。

```swift
import ReduxUIKit

store.observe { $0.count } onChange: { [weak self] count in
  self?.label.text = "\(count)"
}
.retained(by: self)

let button = UIButton(primaryAction: store.action(.increment, title: "+1"))
```

### default MainActor isolation を有効にしたアプリ

Action / State / reducer / Saga はメインアクター外からも使われるため、default MainActor isolation のモジュールでは `nonisolated` を付けて宣言してください（`nonisolated enum Counter: Slice`、`nonisolated let appReducer = ...` など）。推奨構成では、これらを置く `AppFeature` ターゲットは default isolation を使いません。

## テスト

Swift にはジェネレーターがないため、**redux-saga の「Effect を 1 ステップずつ取り出して検証する」テストは書けません**。代わりに、Saga を実際に動かして**結果（発行された Action と State）を検証する**テストを書きます。

```swift
import ReduxTesting
import Testing

@MainActor
@Test func fetch() async throws {
  let store = TestStore(
    initialState: Counter.initialState,
    reducer: Counter.reducer,
    saga: CounterSagas(repository: CounterRepository { 42 }).root
  )
  try await store.send(.fetch) { $0.isLoading = true }
  try store.receive(.fetched(42)) {
    $0.isLoading = false
    $0.count = 42
  }
  try await store.finish()
}
```

- 待ち合わせは実時間ではなく「すべての Saga が Effect（`take` / `delay` / `join` など）で止まったか」で行うため、テストが実行環境の速さに左右されません。
- `delay` / `debounce` / `throttle` は `TestClock` で時間を進めて検証します（`await store.advance(by: .seconds(1))`）。
- Store なしで Saga だけを検証する場合は `SagaTesting` の `SagaTester` を使います。
- `call` で実際の通信など終わらない処理を呼ぶと待ち合わせも終わらないため、テストではスタブを注入してください。

## サンプル

[`Examples/`](Examples) に、ロックインを避ける推奨構成の ToDo アプリ（SwiftUI / UIKit）があります。

```
Examples/
├── ExampleKit/       Domain（本ライブラリに依存しない）と AppFeature（State / Action / Saga）
├── SwiftUIExample/   SwiftUI アプリ
└── UIKitExample/     UIKit アプリ
```

`Examples/Examples.xcodeproj` を Xcode で開いて実行できます。

## ドキュメント

- [設計書](docs/design.md)
- [ロードマップ](docs/roadmap.md)

## 背景

作者が以前 [ReSwift の拡張として実装した Saga](https://github.com/mitsuharu/ReSwift-Saga)（[解説記事](https://qiita.com/mitsuharu_e/items/c2f7893a2c974dd5fc77)）を、Redux 本体も含めて Swift 6 向けに作り直すプロジェクトです。旧実装からの変更点は[設計書 13 章](docs/design.md#13-旧実装reswift-sagaからの変更点)を参照してください。

## ライセンス

[MIT](LICENSE)
