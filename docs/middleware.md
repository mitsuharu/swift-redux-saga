# ミドルウェア

ミドルウェアは、dispatch された Action が reducer に届くまでの間に処理を挟む仕組みです。Action をログに出す、分析ツールにイベントを送る、条件によって Action を止める、といった、どの機能にも共通する処理を 1 か所に書けます。

この文書では、ミドルウェアが Action を受け取る流れ、ミドルウェアの作り方、よくある使い方を順に説明します。最後に、同梱している `LoggingMiddleware` を取り上げます。

## Action がミドルウェアを通る流れ

Store にはミドルウェアを配列で渡します。

```swift
let store = Store(
  initialState: AppState(),
  reducer: appReducer,
  middleware: [LoggingMiddleware(), analyticsMiddleware, sagaMiddleware]
)
```

`store.dispatch(action)` を呼ぶと、Action は配列の先頭のミドルウェアに渡されます。各ミドルウェアが `next(action)` を呼ぶと次のミドルウェアに進み、最後のミドルウェアが `next` を呼ぶと reducer が State を更新します。

```
dispatch → LoggingMiddleware → analyticsMiddleware → sagaMiddleware → reducer
```

`next` は、後ろのミドルウェアと reducer の処理がすべて終わってから戻ります。そのため、`next` を呼ぶ前に `store.state` を読めば Action を適用する前の State が、呼んだ後に読めば適用した後の State が得られます。

ミドルウェアの処理はすべてメインアクターの上で同期的に行われ、`dispatch` から戻った時点で State は更新されています。

## ミドルウェアを作る

ミドルウェアは `Middleware` プロトコルに準拠した型です。必要なのは `handle(_:store:next:)` だけです。

```swift
import Redux

struct PrintMiddleware<State: Sendable, Action: Sendable>: Middleware {
  func handle(_ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void) {
    print("action:", action)
    next(action)
    print("state:", store.state)
  }
}
```

`handle` には 3 つの引数が渡されます。

- `action`: dispatch された Action です。
- `store`: Store の窓口（`MiddlewareAPI`）です。`state` で今の State を読み、`dispatch(_:)` で Action を送れます。
- `next`: 次のミドルウェア（最後は reducer）に Action を渡す関数です。

`next` を呼び忘れると、その Action は reducer に届かず、State も変わりません。Action を止めたいとき以外は、必ず 1 回呼んでください。

特定の State と Action の型にだけ使うミドルウェアなら、ジェネリックにせず型を書いてかまいません。

```swift
struct AuthGuardMiddleware: Middleware {
  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    ...
  }
}
```

ミドルウェアはメインアクターに隔離されています。`handle` の中では、メインアクターの値をそのまま使えます。

## よくある使い方

### Action を見て、外部に知らせる

もっとも多いのは、Action を見て外部のサービスに知らせる使い方です。たとえば、分析ツールにイベントを送るミドルウェアは次のようになります。送り先はプロトコルにしておき、ミドルウェアを作るときに渡します。

```swift
/// 分析ツールの窓口。アプリ側で Firebase などを使って実装する（このライブラリには依存しない）。
@MainActor
protocol Analytics {
  func log(event: String)
}

struct AnalyticsMiddleware: Middleware {
  let analytics: any Analytics

  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    next(action)
    switch action {
    case .todo(.addTapped): analytics.log(event: "todo_added")
    case .auth(.loggedOut): analytics.log(event: "logout")
    default: break
    }
  }
}
```

送り先をプロトコルにしておくと、テストでは記録するだけの型に差し替えられます。分析ツールの SDK を import するのはアプリ側の実装だけで済みます。

### State の変化を見る

`next` の前後で State を比べると、Action によって何が変わったかが分かります。`ReduxPersistence` の `PersistenceMiddleware` も、保存する部分が変わったかをこの方法で調べています。

```swift
struct BadgeMiddleware: Middleware {
  let updateBadge: @MainActor (Int) -> Void

  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    let before = store.state.unreadCount
    next(action)
    let after = store.state.unreadCount
    if before != after {
      updateBadge(after)
    }
  }
}
```

### Action を止める・変える

`next` を呼ばなければ、Action は reducer に届きません。たとえば、ログインしていないときの操作を無視するミドルウェアは次のようになります。

```swift
struct AuthGuardMiddleware: Middleware {
  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    if case .todo = action, !store.state.auth.isLoggedIn {
      return  // ログインしていなければ、ToDo の Action を捨てる
    }
    next(action)
  }
}
```

`next` に別の Action を渡せば、Action を置き換えることもできます。ただし、Action を止めたり変えたりすると、reducer だけを読んでも何が起きるかが分からなくなります。この使い方は、どうしても必要な場合に限ってください。

### Action を追加で送る

`store.dispatch(_:)` で、別の Action を送れます。`handle` の中から送った Action は、今処理している Action が reducer まで届いた後に処理されます。処理の途中で State が書き換わることはありません。

```swift
struct SessionTimeoutMiddleware: Middleware {
  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    next(action)
    if case .api(.unauthorized) = action {
      store.dispatch(.auth(.logout))  // .api(.unauthorized) の処理が終わった後に処理される
    }
  }
}
```

### 非同期の処理はどうするか

`handle` は同期の関数で、`next` も後から呼ぶことはできません。通信のように時間のかかる処理は、ミドルウェアではなく Saga に書いてください。Saga なら、キャンセルや、重なった処理の扱い（`takeLatest` など）も書けます。

結果を待たずに外部へ送るだけの処理（ログの送信など）であれば、ミドルウェアから `Task` を作ってもかまいません。

```swift
struct RemoteLogMiddleware: Middleware {
  let send: @Sendable (String) async -> Void

  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    next(action)
    let message = String(describing: action)
    Task { await send(message) }  // 送信の終わりは待たない
  }
}
```

### Store を保持して、後から使う

`attach(to:)` は、Store を作ったときに 1 回だけ呼ばれます。窓口（`MiddlewareAPI`）を保持しておけば、Action が来ていないときにも State を読んだり Action を送ったりできます。`SagaMiddleware` も、この方法で Saga から Action を送っています。

```swift
@MainActor
final class ClockMiddleware: Middleware {
  private var store: MiddlewareAPI<AppState, AppAction>?

  func attach(to store: MiddlewareAPI<AppState, AppAction>) {
    self.store = store
  }

  func handle(_ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void) {
    next(action)
  }

  /// アプリから呼ぶ（たとえばタイマーで）。
  func tick(now: Date) {
    store?.dispatch(.clock(.tick(now)))
  }
}
```

窓口は Store を弱参照で持つので、ミドルウェアが保持しても循環参照になりません。Store が解放された後の `dispatch` は何もしません。`state` は Store が解放された後に読むとプログラムを停止するので、必要なら先に `isStoreAlive` で確かめてください。

状態を持つミドルウェアは、上の例のようにクラスにします。状態を持たないミドルウェアは構造体で十分です。

## ミドルウェアの順番

ミドルウェアは配列の順に呼ばれます。次の点に気をつけて並べてください。

- Action を止めたり変えたりするミドルウェアより後ろのミドルウェアには、止められた Action は届きません。ログを出すミドルウェアは、すべての Action を見られるよう先頭に置くのが普通です。
- `next` の後で State を読むミドルウェアは、どこに置いても reducer を通った後の State を読めます。

result builder でも並べられます。条件によってミドルウェアを入れたり外したりするときに便利です。

```swift
let store = Store(initialState: AppState()) {
  appReducer
} middleware: {
  LoggingMiddleware()
  if isAnalyticsEnabled {
    AnalyticsMiddleware(analytics: analytics)
  }
  sagaMiddleware
}
```

`store.scope(...)` で作った子の Store は、ミドルウェアを持ちません。子の Store に送った Action は親の Action に包まれて、親の Store のミドルウェアを通ります。

## ミドルウェアと Saga の使い分け

| 処理 | 書く場所 |
| --- | --- |
| すべての Action を対象にした、同期の処理（ログ、分析、State の変化の監視） | ミドルウェア |
| 通信、待ち合わせ、キャンセル、重なった処理の扱いがある処理 | Saga |
| 特定の Action に応えて、ビジネスロジックを呼び、結果を Action で返す処理 | Saga |

迷ったら Saga に書いてください。ミドルウェアはすべての Action のたびに同期で呼ばれるので、重い処理を書くと、画面の操作全体が遅くなります。

## 同梱のミドルウェア: LoggingMiddleware

`LoggingMiddleware` は、dispatch された Action をログに出すミドルウェアです。`Redux` に含まれているので、追加のプロダクトなしで使えます。

```swift
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [
  LoggingMiddleware(),
  sagaMiddleware,
])
```

既定ではデバッグビルドでだけ出力し、リリースビルドでは何もしません（Action を素通しします）。Apple の OS では `os.Logger` の `debug` レベルで出力するので、Xcode のコンソールと Console.app で見られます。それ以外の OS（Linux）では標準出力に出力します。

出力は次のようになります。

```
action: todo(MyApp.TodoAction.addTapped)
state: AppState(todos: [...], ...)
```

値は `String(describing:)` で文字列にしたものです。`state:` の行は、`logsState: true` のときだけ出力します。

### 設定

`LoggingMiddleware` の初期化子の引数で、出力を調整できます。

| 引数 | 既定値 | 説明 |
| --- | --- | --- |
| `isEnabled` | デバッグビルドなら `true` | ログを出すかどうか。リリースビルドでも出したい場合は `true` を渡す |
| `logsState` | `false` | Action を適用した後の State も出すかどうか |
| `privacy` | `.private` | ログに出す値の扱い（後述） |
| `subsystem` / `category` | `"swift-redux-saga"` / `"Redux"` | `os.Logger` の subsystem と category。Console.app での絞り込みに使う |
| `filter` | すべて出す | ログに出す Action を選ぶ関数 |

たとえば、State も出しつつ、頻繁に送られる Action を除くには次のように書きます。

```swift
LoggingMiddleware<AppState, AppAction>(
  logsState: true,
  subsystem: "com.example.MyApp",
  filter: { action in
    if case .clock(.tick) = action { return false }  // 毎秒の Action は出さない
    return true
  }
)
```

### プライバシー

Action や State には、ユーザーの入力や個人情報が含まれることがあります。そこで既定では、値を `.private` として出力します。Xcode から実行しているときのコンソールには表示されますが、端末に残るログ（Console.app で見る、ほかの人の端末のログなど）では `<private>` と伏せられます。

端末のログでも値を見たい場合は `privacy: .public` を渡します。個人情報が含まれないことを確かめてから使ってください。

### 置く場所

`LoggingMiddleware` は、ミドルウェアの配列の先頭に置いてください。Action を止めるミドルウェアより後ろに置くと、止められた Action がログに出ません。

## テスト

ミドルウェアのテストでは、テスト用の Store にミドルウェアを渡し、Action を dispatch して結果を確かめます。`dispatch` は同期で処理されるので、待ち合わせは要りません。

```swift
import Redux
import Testing

/// 送られたイベントを記録する分析ツール。
@MainActor
final class RecordingAnalytics: Analytics {
  var events: [String] = []
  func log(event: String) { events.append(event) }
}

@MainActor
@Test func addingATodoSendsAnEvent() {
  let analytics = RecordingAnalytics()
  let store = Store(
    initialState: AppState(), reducer: appReducer,
    middleware: [AnalyticsMiddleware(analytics: analytics)])

  store.dispatch(.todo(.addTapped))

  #expect(analytics.events == ["todo_added"])
}
```
