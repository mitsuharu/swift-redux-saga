# ReSwift / ReSwift-Saga からの移行ガイド

[ReSwift](https://github.com/ReSwift/ReSwift) と [ReSwift-Saga](https://github.com/mitsuharu/ReSwift-Saga) から swift-redux-saga に移行するための対応表と手順です。

- ReSwift だけを使っている場合は「[ReSwift からの移行](#reswift-からの移行)」を読んでください。
- ReSwift-Saga も使っている場合は、続けて「[ReSwift-Saga からの移行](#reswift-saga-からの移行)」を読んでください。

設計の違いの理由は[設計書](design.md)（特に 4 章の並行性、5 章の Redux、13 章の旧実装からの変更点）を参照してください。

## ReSwift からの移行

### 対応表

| ReSwift | swift-redux-saga（`Redux`） |
| --- | --- |
| `Store<AppState>(reducer:state:middleware:)` | `Store<AppState, AppAction>(initialState:reducer:middleware:)`（`@MainActor`、`Observable`） |
| `protocol Action` に準拠した struct | `Sendable` な enum（存在型 `any AppActionProtocol` も使える） |
| `func appReducer(action: Action, state: AppState?) -> AppState` | `Reducer<AppState, AppAction> { state, action in ... }`（`inout`） |
| 子の reducer を手で呼び分ける | `Reducer.scope` / `Reducer.slice`、`Slice` プロトコル、`@Slice` マクロ |
| `StoreSubscriber` と `subscribe` / `unsubscribe` / `newState(state:)` | SwiftUI では `store.count` を読むだけ。UIKit では `store.observe { ... }`（iOS 26 以降は自動追跡） |
| `subscribe(self) { $0.select { $0.counter } }` | `store.observe { $0.counter } onChange: { ... }` |
| `skipRepeats` / `automaticallySkipsRepeats` | 不要（`Equatable` なプロパティは値が変わったときだけ通知される） |
| `Middleware<AppState>`（`dispatch` / `getState` / `next` のクロージャ） | `Middleware` プロトコルの `handle(_:store:next:)` |
| ReSwift-Thunk などの非同期処理 | Saga（`ReduxSaga` の `SagaMiddleware`） |
| どのスレッドからでも `dispatch` | `dispatch` は `@MainActor`。メインアクター外からは `await store.dispatch(...)` と書く（コンパイラがメインアクターでの実行を保証する） |

### 手順

#### 1. Action と State を Sendable にする

Swift 6 言語モードでは、Store（メインアクター）と Saga（メインアクター外）の間で Action と State を受け渡すため、両方とも `Sendable` にします。Action は enum にすると、`switch` で漏れなく扱えます。

```swift
// Before（ReSwift）
struct IncrementCounter: Action {}
struct SetCounter: Action { let value: Int }

// After
enum CounterAction: Sendable, Equatable {
  case increment
  case set(Int)
}
```

#### 2. reducer を inout にし、Slice にまとめる

```swift
// Before
func counterReducer(action: Action, state: CounterState?) -> CounterState {
  var state = state ?? CounterState()
  switch action {
  case _ as IncrementCounter: state.count += 1
  case let action as SetCounter: state.count = action.value
  default: break
  }
  return state
}

func appReducer(action: Action, state: AppState?) -> AppState {
  AppState(counter: counterReducer(action: action, state: state?.counter))
}

// After（マクロなし）
enum Counter: Slice {
  struct State: Sendable, Equatable { var count = 0 }
  typealias Action = CounterAction
  static let initialState = State()
  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .increment: state.count += 1
    case .set(let value): state.count = value
    }
  }
}

let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(Counter.self, state: \.counter) { if case .counter(let a) = $0 { a } else { nil } }
}

// After（マクロあり）: @ActionCases を AppAction に付けると action: \.counter と書ける
let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(Counter.self, state: \.counter, action: \.counter)
}
```

#### 3. Store を作る

```swift
// Before
let store = Store<AppState>(reducer: appReducer, state: nil, middleware: [loggingMiddleware])

// After（Store は @MainActor。メインアクター外からは await store.dispatch(...) で呼ぶ）
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [LoggingMiddleware()])
```

#### 4. 購読（StoreSubscriber）を置き換える

```swift
// Before（ReSwift）
final class CounterViewController: UIViewController, StoreSubscriber {
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    store.subscribe(self) { $0.select { $0.counter.count }.skipRepeats() }
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    store.unsubscribe(self)
  }
  func newState(state: Int) { label.text = "\(state)" }
}

// After（UIKit、iOS 17 から）
override func viewDidLoad() {
  super.viewDidLoad()
  store.observe { $0.counter.count } onChange: { [weak self] count in
    self?.label.text = "\(count)"
  }
  .retained(by: self)   // View Controller が解放されると購読も止まる
}

// After（UIKit、iOS 26 以降）: 読むだけで自動で追跡される
override func updateProperties() {
  super.updateProperties()
  label.text = "\(store.counter.count)"
}

// After（SwiftUI）
struct CounterView: View {
  @Environment(Store<AppState, AppAction>.self) private var store
  var body: some View { Text("\(store.counter.count)") }
}
```

`select` と `skipRepeats` に相当する処理は不要です。Store のプロパティを直接読むと、そのプロパティの値が変わったときだけ通知されます（設計書 5.4）。

#### 5. ミドルウェアを書き換える

Action をログに出すだけなら、組み込みの `LoggingMiddleware` を使えます（デバッグビルドでだけ `os.Logger` に出力）。

```swift
// Before（ReSwift）
let loggingMiddleware: Middleware<AppState> = { dispatch, getState in
  { next in
    { action in
      print(action)
      next(action)
    }
  }
}

// After（組み込み）
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [LoggingMiddleware()])

// After（自分で書く場合）
struct AnalyticsMiddleware: Middleware {
  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    analytics.track(action)
    next(action)
  }
}
```

`next` はその場でしか呼べません（エスケープしない）。非同期の処理は、ミドルウェアではなく Saga に書いてください。

#### 6. 非同期処理（ReSwift-Thunk など）を Saga にする

```swift
// Before（ReSwift-Thunk）
let fetchCounter = Thunk<AppState> { dispatch, getState in
  Task {
    let value = try await api.fetchCounter()
    dispatch(SetCounter(value: value))   // ReSwift はスレッドを保証しない
  }
}

// After（Saga）
struct CounterSagas: Sendable {
  let fetchCounter: @Sendable () async throws -> Int   // 依存は注入する

  var root: Saga<AppState, AppAction> {
    Saga { ctx in
      ctx.takeLatest(.action(.counter(.fetch))) { ctx, _ in
        let value = try await ctx.call(fetchCounter)
        await ctx.put(.counter(.set(value)))
      }
    }
  }
}
```

Saga の書き方は「[ReSwift-Saga からの移行](#reswift-saga-からの移行)」と README を参照してください。

#### 7. テストを書き換える

reducer は純粋関数なので、そのまま `reduce(into:action:)` を呼んでテストできます。Store と Saga をまとめて検証するときは `ReduxTesting` の `TestStore` を使います。

## ReSwift-Saga からの移行

### 対応表

| ReSwift-Saga | swift-redux-saga |
| --- | --- |
| `import ReSwift` の `Store<AppState>` | `import Redux` の `Store<AppState, AppAction>`（`@MainActor`、`Observable`） |
| `Reducer<AppState>`（`(Action, AppState?) -> AppState`） | `Reducer<AppState, AppAction>`（`(inout AppState, AppAction) -> Void`） |
| `protocol UserAction: Action` と struct の Action | `enum AppAction` の case（型で分けるスタイルも `ActionPattern.type` で使える） |
| `createSagaMiddleware()` | `SagaMiddleware<AppState, AppAction>()` |
| `typealias Saga = (Action) async -> Void` | `Saga<AppState, AppAction> { ctx in ... }` |
| `take(RequestUser.self)` | `try await ctx.take(.type(RequestUser.self))` / `ctx.take(.case { ... })` |
| `put(action)` | `await ctx.put(action)` |
| `select(selector)` | `await ctx.select(selector)` |
| `call(saga, action)` | `try await ctx.call(function, arguments...)`（任意の async 関数） |
| `fork(saga)`（`Task.detached`） | `ctx.fork(saga)`（親の子タスク。キャンセルが伝わる）。切り離すなら `ctx.spawn(saga)` |
| `takeEvery(RequestUser.self, saga: worker)` | `ctx.takeEvery(.type(RequestUser.self)) { ctx, action in ... }` |
| `takeLatest` / `takeLeading` | `ctx.takeLatest` / `ctx.takeLeading` |
| `StoreSubscriber` と `subscribe` / `unsubscribe` | SwiftUI では `store.count` を読むだけ。UIKit では `store.observe { ... }`（iOS 26 以降は自動追跡） |
| `Bridge.shared`（グローバル） | なし（Action の配信はミドルウェアのインスタンスが持つ） |

### 手順

#### 1. Action を enum にする

```swift
// Before
protocol UserAction: Action {}
struct RequestUser: UserAction { let userID: String }
struct StoreUserName: UserAction { let name: String }

// After
enum UserAction: Sendable, Equatable {
  case request(userID: String)
  case storeName(String)
}
```

struct のまま移行したい場合は、Action をプロトコルの存在型（`any AppActionProtocol`）にして `ActionPattern.type(RequestUser.self)` で判定できます。ただし Action と State は `Sendable` にしてください。

#### 2. reducer を inout にする

```swift
// Before
func userReducer(action: Action, state: UserState?) -> UserState {
  var state = state ?? UserState()
  if let action = action as? StoreUserName { state.name = action.name }
  return state
}

// After
let userReducer = Reducer<UserState, UserAction> { state, action in
  if case .storeName(let name) = action { state.name = name }
}
```

#### 3. Saga を SagaContext を受け取る形にする

旧実装の Saga は Action を引数に取り、ワーカーが Action をキャストしていました。新しい Saga は `SagaContext` を受け取り、ワーカーにはパターンで取り出した値だけが渡ります。

```swift
// Before
let userSaga: Saga = { _ in
  await takeEvery(RequestUser.self, saga: requestUserSaga)
}
let requestUserSaga: Saga = { action async in
  guard let action = action as? RequestUser else { return }
  let name = try? await api.fetchUserName(action.userID)
  try? await put(StoreUserName(name: name ?? ""))
}

// After
struct UserSagas: Sendable {
  let fetchUserName: @Sendable (String) async throws -> String   // 依存は注入する

  var root: Saga<UserState, UserAction> {
    Saga("user") { ctx in
      ctx.takeEvery(.case { if case .request(let id) = $0 { id } else { nil } }) { ctx, userID in
        let name = (try? await ctx.call(fetchUserName, userID)) ?? ""
        await ctx.put(.storeName(name))
      }
    }
  }
}
```

#### 4. Store と Saga を組み立てる

```swift
@MainActor
func makeStore(api: UserAPI) -> Store<UserState, UserAction> {
  let sagaMiddleware = SagaMiddleware<UserState, UserAction>()
  let store = Store(initialState: UserState(), reducer: userReducer, middleware: [sagaMiddleware])
  sagaMiddleware.run(UserSagas(fetchUserName: api.fetchUserName).root)
  return store
}
```

Saga は `run` から非同期に動き出しますが、`run` の直後に dispatch した Action は、起動した Saga が最初の Effect に達するまで溜めて後から届けます。redux-saga / 旧実装と同じく、起動直後の Action を取りこぼしません（[設計書 7 章](design.md#起動直後の-actionredux-saga-との違い)）。

#### 5. View の購読を置き換える

```swift
// Before（ObservableObject + StoreSubscriber）
final class UserViewModel: ObservableObject, StoreSubscriber { ... }

// After（SwiftUI）
struct UserView: View {
  @Environment(Store<UserState, UserAction>.self) private var store
  var body: some View {
    Text(store.name)   // name が変わったときだけ再描画される
    Button("Load") { store.dispatch(.request(userID: "1234")) }
  }
}
```

#### 6. テストを結果の検証にする

`SagaTester`（Saga だけ）や `TestStore`（Store と Saga）で、送った Action に対して発行された Action と State を検証します。詳しくは [README](../README.md#テスト) を参照してください。
