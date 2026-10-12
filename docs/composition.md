# 機能を組み合わせる

アプリが大きくなると、ログイン、ToDo、設定のように、機能ごとに State・Action・reducer・Saga を分けたくなります。この文書では、機能ごとに書いたものを 1 つのアプリにまとめる方法と、機能の Saga を動かす期間（ログイン中だけ、画面の表示中だけなど）の決め方を説明します。

1 つの機能の書き方は[はじめかた](getting-started.md)を参照してください。この文書のコードは、[サンプル](../Examples)の構成を簡単にしたものです。

## Store は 1 つ、機能ごとに分けるのは型

機能を分けても、Store はアプリに 1 つだけ作ります。アプリ全体の State は、機能ごとの State をプロパティとして持つ構造体にします。

```
AppState
├── auth: AuthFeature.State    ログイン
└── todo: TodoFeature.State    ToDo
```

State を 1 か所に置くので、機能をまたいだデータ（ログイン中のユーザーなど）を、どの機能からも同じ値として読めます。一方で、機能のコードはアプリ全体の型を知らずに、自分の State と Action だけで書けます。そのための仕組みが、この文書で説明する `Reducer.slice`、`Store.scope`、Saga の scope です。

## 機能ごとの State と Action

まず、機能ごとに State・Action・reducer を書きます。ほかの機能のことは知りません。ここでは `Slice` への準拠を `@Slice` マクロ（`ReduxMacros`）で書いています。`@Slice` は `Slice` への準拠に加えて、`Action` に `@ActionCases` を付けます（`@ActionCases` は後で説明します）。

```swift
import Redux
import ReduxMacros

@Slice
nonisolated enum AuthFeature {
  struct State: Sendable, Equatable {
    var user: User?
    var isLoggingIn = false
  }

  enum Action: Sendable, Equatable {
    case loginTapped(name: String)
    case logoutTapped
    case loggedIn(User)
    case loggedOut
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .loginTapped: state.isLoggingIn = true
    case .logoutTapped: break
    case .loggedIn(let user):
      state.isLoggingIn = false
      state.user = user
    case .loggedOut: state.user = nil
    }
  }
}

@Slice
nonisolated enum TodoFeature {
  struct State: Sendable, Equatable {
    var todos: [Todo] = []
    var isLoading = false
  }

  enum Action: Sendable, Equatable {
    case refreshTapped
    case loaded([Todo])
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .refreshTapped: state.isLoading = true
    case .loaded(let todos):
      state.isLoading = false
      state.todos = todos
    }
  }
}
```

（`nonisolated` は、default MainActor isolation を有効にしたターゲットで必要です。[はじめかた](getting-started.md#準備)を参照してください。）

## アプリ全体の State と Action

アプリ全体の State は、機能の State をプロパティに持ちます。アプリ全体の Action は、機能の Action を関連値に持つ case を並べた enum にします。

```swift
nonisolated struct AppState: Sendable, Equatable {
  var auth = AuthFeature.State()
  var todo = TodoFeature.State()
}

@ActionCases
nonisolated enum AppAction: Sendable, Equatable {
  case auth(AuthFeature.Action)
  case todo(TodoFeature.Action)
}
```

View から ToDo の更新を送るときは `.todo(.refreshTapped)` のように、機能の Action を包んで送ります。

### case のキーパス（`@ActionCases`）

機能の Action を取り出す処理は、何度も出てきます。`@ActionCases`（`ReduxMacros`）を enum に付けると、case ごとに関連値を取り出すプロパティが生成されます。

```swift
// @ActionCases が生成するプロパティ（イメージ）
extension AppAction {
  var auth: AuthFeature.Action? { if case .auth(let action) = self { action } else { nil } }
  var todo: TodoFeature.Action? { if case .todo(let action) = self { action } else { nil } }
}
```

このプロパティはキーパスとして渡せます。以降のコードに出てくる `\.todo`（`AppAction` から `TodoFeature.Action` を取り出す）や `\.auth?.loggedIn`（ログインした `User` を取り出す）は、このプロパティを指しています。機能の Action にも `@ActionCases` が付いているので（`@Slice` が付けます）、`\.auth?.loggedIn` のようにつないで書けます。

マクロを使わない場合は、キーパスの代わりにクロージャを渡します。

```swift
Reducer.slice(TodoFeature.self, state: \.todo) {
  if case .todo(let action) = $0 { action } else { nil }
}
```

## reducer をまとめる

機能の reducer は、`Reducer.slice` でアプリ全体の State と Action に持ち上げ、並べます。

```swift
nonisolated let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(AuthFeature.self, state: \.auth, action: \.auth)
  Reducer.slice(TodoFeature.self, state: \.todo, action: \.todo)
}
```

`Reducer.slice(TodoFeature.self, state: \.todo, action: \.todo)` は、「`AppAction` が `.todo` の case なら、中身の Action を `TodoFeature` の reducer に渡し、`AppState.todo` を書き換える」という reducer になります。ほかの case の Action は無視します。

### 機能をまたぐ処理

「ログアウトしたら ToDo の一覧を消す」のように、ある機能の Action で別の機能の State を変えたい場合は、アプリ全体の reducer に書きます。機能の reducer は、ほかの機能の Action を知らないままにしておきます。

```swift
nonisolated let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(AuthFeature.self, state: \.auth, action: \.auth)
  Reducer.slice(TodoFeature.self, state: \.todo, action: \.todo)
  Reducer { state, action in
    if case .auth(.loggedOut) = action {
      state.todo = TodoFeature.State()
    }
  }
}
```

reducer は上から順に適用されます。

## 機能の View に、機能の Store を渡す

機能の View や ViewModel に、アプリ全体の `Store<AppState, AppAction>` を渡すと、機能のコードがアプリ全体の型に依存してしまいます。`store.scope(state:action:)` で、機能の State と Action だけを扱う Store を作って渡してください。

```swift
let todoStore = store.scope(state: \.todo, action: AppAction.todo)  // Store<TodoFeature.State, TodoFeature.Action>

TodoListView()
  .store(todoStore)
```

- `state:` には、アプリ全体の State から機能の State を取り出すキーパスを渡します。
- `action:` には、機能の Action をアプリ全体の Action に包む関数を渡します。enum の case（`AppAction.todo`）はそのまま関数として渡せます。

scope した Store は State を持たず、親の Store から読みます。機能の Store に dispatch した Action は、`AppAction.todo` で包まれて親の Store に送られ、親のミドルウェアと reducer を通ります。読み取りの追跡もプロパティ単位のままなので、`todoStore.todos` を読む View は `todos` が変わったときだけ再描画されます。

## Saga をつなぐ

Saga も、機能の State と Action の型のまま書きます。

```swift
import Saga

nonisolated struct TodoSagas: Sendable {
  let repository: TodoRepository

  var root: Saga<TodoFeature.State, TodoFeature.Action> {
    Saga("todo") { ctx in
      ctx.takeLatest(.action(.refreshTapped)) { ctx, _ in
        do {
          let todos = try await ctx.call(repository.fetchAll)
          await ctx.put(.loaded(todos))
        } catch is CancellationError {
        } catch {
          await ctx.put(.loaded([]))
        }
      }
    }
  }
}
```

機能の Saga は、アプリ全体の State と Action に接続して起動します。接続のしかたは reducer の `slice` と同じです。

```swift
sagaMiddleware.run(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)
```

- `state:`: 機能の Saga の `select` が読む State（`AppState.todo`）
- `action:`: 機能の Saga の `take` に届く Action（`AppAction` が `.todo` の case のときの中身）
- `embed:`: 機能の Saga が `put` した Action を、アプリ全体の Action に包む関数

接続した後も、機能の Saga の中身は機能の型だけで書けます。

## Saga を動かす期間

Saga には、アプリの起動中ずっと動かすものと、ログイン中だけ、画面の表示中だけ動かしたいものがあります。動かす期間に合わせて、起動と停止を対応させます。

### アプリの起動中ずっと

Store を作った直後に `run` します。ログインの Saga などが当たります。

```swift
let sagaMiddleware = SagaMiddleware<AppState, AppAction>()
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [sagaMiddleware])
sagaMiddleware.run(authSagas.root, state: \.auth, action: \.auth, embed: AppAction.auth)
```

`run` で起動した Saga は、`run` を呼んだ側の Task とは独立して動きます。`sagaMiddleware.stop()` は、Store を捨てるときに Saga をすべて止めるためのもので、止めた後は二度と動きません。

### ログイン中だけ

ログイン中だけ動かす Saga は、アプリ全体の Saga（ルート Saga）の中で、ログインしたら `ctx.fork` で起動し、ログアウトしたら `ctx.cancel` で止めます。

```swift
nonisolated struct RootSagas: Sendable {
  let auth: AuthSagas
  let todo: TodoSagas

  var root: Saga<AppState, AppAction> {
    Saga("root") { ctx in
      ctx.fork(auth.root, state: \.auth, action: \.auth, embed: AppAction.auth)
      while true {
        _ = try await ctx.take(.case(\.auth?.loggedIn))
        let session = ctx.fork(todo.root, state: \.todo, action: \.todo, embed: AppAction.todo)
        _ = try await ctx.take(.case(\.auth?.loggedOut))
        ctx.cancel(session)
      }
    }
  }
}

sagaMiddleware.run(rootSagas.root)
```

- `ctx.fork` は、子の Saga を起動し、その Saga を表す値（`SagaTask`）を返します。fork した子は親の Saga の子タスクになるので、親が止まれば子も止まります。
- `ctx.cancel(session)` で子を止めると、子が実行中の通信（`call`）もキャンセルされます。

止めるのが間に合わない場合があることに注意してください。通信が終わってから結果を `put` するまでの間にログアウトされると、ログアウトの後に前のセッションの結果が届くことがあります。結果を確実に捨てるには、State にセッションの番号（世代）を持たせ、Saga は処理を始めた時点の世代を結果の Action に含めます。reducer は、今の世代と違う結果を捨てます。サンプルの `TodoFeature.State.generation` がこの方法です。

また、上の例では、ログインの前に起動済みかどうかを State で調べていません。起動時にすでにログインしている場合も扱うなら、最初に `ctx.select` で State を読み、その間に届く Action を取りこぼさないよう、先に `actionChannel` で Action を溜めておきます。サンプルの [`RootSagas`](../Examples/ExampleKit/Sources/AppFeature/RootFeature.swift) を参照してください。

### 画面の表示中だけ

検索画面の Saga のように、画面を表示している間だけ動かす場合は、SwiftUI の `.task` の中で `run` し、`.task` のキャンセル（画面が消えたとき）で Saga を止めます。`run` は呼び出し元の Task のキャンセルを受け取らないので、`withTaskCancellationHandler` でつなぎます。

```swift
struct SearchScreen: View {
  let sagaMiddleware: SagaMiddleware<AppState, AppAction>
  let searchSagas: SearchSagas

  var body: some View {
    SearchView()
      .task {
        let task = sagaMiddleware.run(
          searchSagas.root, state: \.search, action: \.search, embed: AppAction.search)
        await withTaskCancellationHandler {
          _ = try? await task.join()
        } onCancel: {
          task.cancel()
        }
      }
  }
}
```

UIKit では、`viewDidAppear` で `run` し、返された `SagaTask` を `viewDidDisappear` で `cancel()` します。

## まとめ

| やりたいこと | 使うもの |
| --- | --- |
| 機能の reducer をアプリ全体の型に持ち上げる | `Reducer.slice(_:state:action:)` |
| 機能の View・ViewModel に機能の型の Store を渡す | `store.scope(state:action:)` |
| 機能の Saga をアプリ全体に接続する | `sagaMiddleware.run(_:state:action:embed:)` / `ctx.fork(_:state:action:embed:)` |
| ある機能の Action で別の機能の State を変える | アプリ全体の reducer に書く |
| Saga をログイン中だけ動かす | ルート Saga で `fork` と `cancel` |
| Saga を画面の表示中だけ動かす | `.task` の中で `run` し、キャンセルで止める |
