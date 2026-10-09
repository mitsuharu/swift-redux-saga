# swift-redux-saga

Swift 6 で書かれた Redux（[Redux Toolkit](https://redux-toolkit.js.org/) を参考にした実装）と、その上で動く [Redux Saga](https://redux-saga.js.org/) の Swift Package です。

> [!WARNING]
> 1.0.0 までは、マイナーバージョン（0.x）でも公開 API が変わることがあります。変更は [CHANGELOG](CHANGELOG.md) に記録します。

## 特徴

- **Swift 6 言語モード**（strict concurrency）で警告ゼロ。Store は `@MainActor`、Saga はメインアクター外で動きます
- **外部ライブラリに依存しない**（標準ライブラリと Apple 公式フレームワークのみ）
- **構造化並行性で実装した Saga**: `fork` した子は親のタスクの子タスクになり、キャンセルは親から子へ必ず伝わります
- **ロックインを避ける設計**: ビジネスロジック（UseCase / Repository）は本ライブラリを import せずに書け、Saga は「Action → ビジネスロジック → Action」の薄い層になります
- **Observation 対応**: SwiftUI ではプロパティ単位で再描画され、UIKit の自動追跡（iOS 26 以降、iOS 18 はオプトイン）にも乗れます
- **テストしやすい**: 実時間に依存しない `TestClock` と、Saga や Store の結果を検証する `SagaTester` / `TestStore`
- **そのほか**: マクロ（`@Slice` / `@ActionCases` / `@TrackedState`）、入力欄の Binding、State の永続化、ログ出力のミドルウェア

## 動作環境

- Swift 6.2 以降（Xcode 26 以降）
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 以降
- UI に依存しないプロダクト（`Redux` / `Saga` / `ReduxSaga` / `ReduxMacros` / `ReduxPersistence` / `SagaTesting` / `ReduxTesting`）は Linux でも動きます

## インストール

`Package.swift` の `dependencies` にパッケージを追加します。

```swift
dependencies: [
  .package(url: "https://github.com/mitsuharu/swift-redux-saga.git", from: "0.1.0")
]
```

続けて、用途に合わせてプロダクトを target の `dependencies` に追加します。各プロダクトは、使うのに必要なプロダクトを含んでいます（例: `ReduxSaga` だけを追加すれば `Redux` と `Saga` も `import` できます）。

### 用途ごとのプロダクト

| 用途 | 追加するプロダクト | |
| --- | --- | --- |
| Redux（Store / Reducer / Slice / Selector など）だけを使う | `Redux` | 必須 |
| Redux と Saga を使う | `ReduxSaga` | 必須（`Redux` と `Saga` を含むので、別に追加しなくてよい） |
| Saga だけを、ほかの状態管理と組み合わせて使う | `Saga` | 必須 |
| SwiftUI のヘルパー（`store.binding` / `.store(_:)`） | `ReduxSwiftUI` | 任意 |
| UIKit のヘルパー（`retained(by:)` / `store.action`） | `ReduxUIKit` | 任意 |
| マクロ（`@Slice` / `@ActionCases` / `@TrackedState`） | `ReduxMacros` | 任意（swift-syntax を使います） |
| State の永続化（`Persistence` / `PersistenceMiddleware`） | `ReduxPersistence` | 任意 |
| テスト（`TestStore` / `SagaTester` / `TestClock`） | `ReduxTesting`（Store と Saga）、`SagaTesting`（Saga だけ） | 任意（テストのターゲットに追加） |

`LoggingMiddleware` は `Redux` に含まれます。

### 例: Redux + Saga の SwiftUI アプリ

```swift
targets: [
  .target(
    name: "AppFeature",
    dependencies: [
      .product(name: "ReduxSaga", package: "swift-redux-saga"),
      .product(name: "ReduxMacros", package: "swift-redux-saga"),        // 任意
      .product(name: "ReduxPersistence", package: "swift-redux-saga"),   // 任意
    ]
  ),
  .target(
    name: "App",
    dependencies: [
      "AppFeature",
      .product(name: "ReduxSwiftUI", package: "swift-redux-saga"),       // 任意
    ]
  ),
  .testTarget(
    name: "AppFeatureTests",
    dependencies: [
      "AppFeature",
      .product(name: "ReduxTesting", package: "swift-redux-saga"),
    ]
  ),
]
```

Xcode のプロジェクトでは、File > Add Package Dependencies からパッケージを追加し、同じ表を見てプロダクトを選んでください。マクロ（`ReduxMacros`）は、初めて使うときに Xcode が許可を求めます。

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

#### エラー処理

ワーカーで処理しなかったエラーは、redux-saga と同じく fork 元に伝わります。`takeEvery` などのヘルパーはワーカーが失敗するとヘルパーごと終了し、エラーはルート Saga まで伝わって、**すべての Saga が止まります**。アプリは動き続けますが、以降の Action に Saga が反応しなくなります（エラーは `onError` に渡され、既定ではログに出ます）。

失敗し得る処理は、ワーカーの中で `catch` して Action で返してください。`CancellationError`（`takeLatest` で前のワーカーが止められたときなど）はエラーとして扱いません。

```swift
ctx.takeEvery(fetch) { ctx, id in  // fetch は上の ActionPattern
  do {
    let user = try await ctx.call(repository.fetchUser, id)
    await ctx.put(.fetched(user))
  } catch is CancellationError {
  } catch {
    await ctx.put(.failed(error.localizedDescription))
  }
}
```

ワーカーが多い場合は、この `do` / `catch` を関数にまとめると書きやすくなります（[Example の `perform`](Examples/ExampleKit/Sources/AppFeature/TodoFeature.swift)）。

想定外のエラーに気づけるよう、`onError` でクラッシュレポートのサービスなどに送ることもできます。

```swift
let sagaMiddleware = SagaMiddleware<AppState, AppAction>(onError: { error in
  SagaRuntime<AppState, AppAction>.logError(error)  // 既定のログ出力
  // error.underlying（元のエラー）と error.sagaStack（Saga の経路）を送る
})
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

> [!NOTE]
> Saga は `run` から非同期に動き出しますが、`run` の直後（View の表示時など）に dispatch した Action も取りこぼしません。起動した Saga が最初の Effect に達するまで溜めておき、後から届けます（redux-saga の `run` がルート Saga を最初の Effect まで同期に進めるのと同じ結果になります）。

#### ログ出力（LoggingMiddleware）

`LoggingMiddleware` は、dispatch された Action を `os.Logger` に出力します。既定ではデバッグビルドでだけ出力します。値は `.private` として出力するので、Xcode から実行しているときのコンソールには表示され、端末のログでは伏せられます。

```swift
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [
  LoggingMiddleware(),          // logsState: true で適用後の State も出す
  sagaMiddleware,
])
```

#### State の永続化（ReduxPersistence）

State のうち保存したい部分を選び、起動時に復元します。保存先は `UserDefaultsStorage` / `FileStorage` / `InMemoryStorage` から選べ、差し替えもできます。

```swift
import ReduxPersistence

let persistence = Persistence<AppState, Settings>(
  key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)

let persistenceMiddleware = PersistenceMiddleware<AppState, AppAction>(persistence)
let store = Store(
  initialState: persistence.restore(into: AppState()),   // 起動時に復元
  reducer: appReducer,
  middleware: [persistenceMiddleware]                     // 変わったら保存
)

// 保存は変わってから少し待って（既定 0.5 秒）まとめて行うため、バックグラウンドに入ったらすぐ保存する
.onChange(of: scenePhase) { _, phase in
  if phase == .background { Task { await persistenceMiddleware.flush() } }
}
```

保存形式を変えたときは `version` を上げ、`migrate` で古い形式から変換できます。読み込み中やエラーのような一時的な状態は保存しないでください。

#### ネストしたプロパティ単位の再描画

`store.profile.name` のようにネストしたプロパティを読む場合、`profile` の型に `@TrackedState`（`ReduxMacros`）を付けると、`name` が変わったときだけ再描画されます（付けないと `profile` のどこが変わっても再描画されます）。

```swift
@TrackedState
struct Profile: Sendable, Equatable {
  var name: String = ""
  var age: Int = 0
}
```

### dispatch とメインアクター

`Store` は `@MainActor` なので、`dispatch` はコンパイラがメインアクター上での実行を保証します。メインアクター外から呼ぶときは `await` を付けます（付け忘れるとコンパイルエラーになります）。

```swift
Task.detached {
  let value = try await api.fetch()
  await store.dispatch(.loaded(value))   // メインアクターで実行される
}
```

非同期の処理の結果を Store に反映する場合は、Saga の `put` を使うのがおすすめです。

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

// 親で .store(store) を付ける。
```

`TextField` や `Toggle` など、値を書き戻すだけの入力欄は、State のプロパティに `@BindableState` を付け、Action に `case binding(BindingAction<State>)` を用意すると、部品ごとに Action を書かずに済みます。

```swift
struct State: Sendable, Equatable {
  @BindableState var draft = ""
}
enum Action: Sendable, BindableAction {
  case binding(BindingAction<State>)
}
// reducer: case .binding(let binding): binding.apply(to: &state)（または Reducer.binding を並べる）

TextField("New ToDo", text: store.binding(\.$draft))
```

一覧の要素は、添字（`\.todos[index]`）ではなく ID で読んでください。Store は読んだキーパスを覚えて変化を判定するため、添字で読んだ要素を削除すると範囲外になり、プログラムが停止します。`Identifiable` の配列は `[id:]` で、`EntityState` は `entities[id]` で読めます（要素がなければ `nil`）。Optional の値の `Binding` は `default:` を指定して作ります。

```swift
ForEach(store.todos) { todo in
  TextField("Title", text: store.binding(\.todos[id: todo.id]?.title, default: "") {
    .rename(id: todo.id, title: $0)
  })
}
// reducer: case .rename(let id, let title): state.todos[id: id]?.title = title
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

### Store を直接使うか、MVVM を経由するか

画面ごとに、次の 2 つの書き方を使い分けられます（[サンプル](#サンプル)に両方あります）。

| 書き方 | 向いている画面 |
| --- | --- |
| View / ViewController が Store を直接読み、dispatch する | 画面特有の状態がなく、Store の値を表示して操作するだけの単純な画面（設定画面など） |
| MVVM を経由する（View は ViewModel だけを見る） | 入力中の文字列や選択中の項目など、画面特有の状態や判断がある画面 |

画面特有の状態まで Store に置くと、State が画面の都合で大きくなります。その場合は MVVM と併用し、画面特有の状態は ViewModel に持たせ、複数の画面で使うデータと Saga が関わる処理は Store に置いてください。

```swift
@MainActor
@Observable
final class TodoListViewModel {
  private let store: Store<TodoFeature.State, TodoFeature.Action>
  var draft = ""                                   // 画面特有の状態は ViewModel に

  init(store: Store<TodoFeature.State, TodoFeature.Action>) { self.store = store }

  var todos: [Todo] { TodoFeature.visibleTodos(store.state) }   // 共有データは Store から読む
  var isLoading: Bool { store.isLoading }

  func add() {
    store.dispatch(.add(title: draft))
    draft = ""
  }
}
```

ViewModel には Store の値の写しを持たせず、計算プロパティで Store を読みます（single source of truth を保つため。ViewModel が持つのは Store にない画面特有の状態だけです）。ViewModel の計算プロパティが Store を読むので、Observation がそのまま連鎖し、Store が変わると View も更新されます。View / ViewController は ViewModel だけを見ます。UIKit で iOS 26 未満にも対応する場合は、`ObservationToken.observe { viewModel.todos } onChange: { ... }` で ViewModel を購読できます。

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

#### 通信が重なる場合のテスト

検索語の連続した変更、通信中のログアウト、結果の到着順の逆転などは、応答をテストから手動で返すスタブで再現します。通信中は Saga が止まらないため、`send` の代わりに待たずに送る `dispatch` を使い、Saga が出す Action は届くまで待つ `receive(_:timeout:)` で確かめます（`SagaTester` にも同じ API があります）。

```swift
try store.dispatch(.search("a")) { $0.query = "a" }
try store.dispatch(.search("ab")) { $0.query = "ab" }   // 1 つ目の通信が終わる前に変える
api.respond(to: "ab", with: "ab results")              // 新しい方が先に戻る
try await store.receive(.results("ab results"), timeout: .seconds(5)) { $0.results = "ab results" }
api.respond(to: "a", with: "a results")                // 古い方は takeLatest が止めたので届かない
try await store.finish()
```

`finish()` はすべての Saga が止まるまで待つので、その前にスタブの応答をすべて返してください。

## サンプル

[`Examples/`](Examples) に、ロックインを避ける推奨構成の ToDo アプリ（SwiftUI / UIKit）があります。

```
Examples/
├── ExampleKit/       Domain（本ライブラリに依存しない）と AppFeature（State / Action / Saga / ViewModel）
├── SwiftUIExample/   SwiftUI アプリ
└── UIKitExample/     UIKit アプリ
```

- ToDo の画面は MVVM を経由し（画面特有の状態は ViewModel、共有データと Saga が関わる処理は Store）、設定の画面は Store を直接使っています。
- `@Slice` / `@ActionCases`、`@BindableState`、`takeLatest` / `actionChannel` / `debounce`、`LoggingMiddleware`、設定の永続化（`ReduxPersistence`）、`TestStore` によるテストを使っています。

`Examples/Examples.xcodeproj` を Xcode で開いて実行できます。

## ドキュメント

- [変更履歴（CHANGELOG）](CHANGELOG.md)
- [設計書](docs/design.md)
- [ロードマップ](docs/roadmap.md)
- [ReSwift / ReSwift-Saga からの移行ガイド](docs/migration.md)

## 背景

作者が以前 [ReSwift の拡張として実装した Saga](https://github.com/mitsuharu/ReSwift-Saga)（[解説記事](https://qiita.com/mitsuharu_e/items/c2f7893a2c974dd5fc77)）を、Redux 本体も含めて Swift 6 向けに作り直すプロジェクトです。旧実装からの変更点は[設計書 13 章](docs/design.md#13-旧実装reswift-sagaからの変更点)、ReSwift / ReSwift-Saga からの移行は[移行ガイド](docs/migration.md)を参照してください。

## ライセンス

[MIT](LICENSE)
