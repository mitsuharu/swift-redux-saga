# ReSwift-Saga からの移行ガイド

[ReSwift-Saga](https://github.com/mitsuharu/ReSwift-Saga) から swift-redux-saga に移行するための対応表と手順です。設計の違いの理由は[設計書 13 章](design.md#13-旧実装reswift-sagaからの変更点)を参照してください。

## 対応表

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

## 手順

### 1. Action を enum にする

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

### 2. reducer を inout にする

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

### 3. Saga を SagaContext を受け取る形にする

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

### 4. Store と Saga を組み立てる

```swift
@MainActor
func makeStore(api: UserAPI) -> Store<UserState, UserAction> {
  let sagaMiddleware = SagaMiddleware<UserState, UserAction>()
  let store = Store(initialState: UserState(), reducer: userReducer, middleware: [sagaMiddleware])
  sagaMiddleware.run(UserSagas(fetchUserName: api.fetchUserName).root)
  return store
}
```

起動直後の Action の扱いが redux-saga / 旧実装と異なります。`run` の直後に dispatch した Action は、まだ待ち始めていない Saga に届かないことがあるため、起動時の処理はルート Saga の中に書いてください（[設計書 7 章](design.md#起動直後の-actionredux-saga-との違い)）。

### 5. View の購読を置き換える

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

### 6. テストを結果の検証にする

`SagaTester`（Saga だけ）や `TestStore`（Store と Saga）で、送った Action に対して発行された Action と State を検証します。詳しくは [README](../README.md#テスト) を参照してください。
