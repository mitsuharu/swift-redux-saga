# Saga の Effect: redux-saga との対応

[README](../README.md#saga) の対応表の各行について、redux-saga（JavaScript）と swift-redux-saga のコード例を並べて説明します。

- Saga は `SagaContext`（以下 `ctx`）を受け取る async 関数です。redux-saga の `yield` の代わりに、`ctx` の Effect を `await` で呼びます。
- Effect はすべて `ctx` のメソッドです。トップレベル関数にしていないので、`take` や `call` などの一般的な名前が、ほかのモジュールの関数と衝突しません。
- キャンセルは Swift の `CancellationError` で伝わります。待つ Effect（`take` / `call` / `delay` / `join` など）は、キャンセルされると `CancellationError` を投げます。

## 例で使う型

以降の例は、次の型を使います。ビジネスロジック（`UserAPI`）は本ライブラリに依存しません。

```swift
import Saga

struct User: Sendable, Equatable {
  let id: Int
  var name: String
}

// Domain（本ライブラリを import しない）
struct UserAPI: Sendable {
  let fetch: @Sendable (Int) async throws -> User
  let search: @Sendable (String) async throws -> [User]
  let save: @Sendable (User) async throws -> Void
}

struct AppState: Sendable, Equatable {
  var user: User?
  var token: String?
}

enum AppAction: Sendable, Equatable {
  case fetch(Int)
  case fetched(User)
  case failed(String)
  case search(String)
  case results([User])
  case save(User)
  case saved
  case scrolled(Int)
  case login
  case logout
  case tick
}

// Action から値を取り出すパターン（@ActionCases マクロを使えば `.case(\.fetch)` と書ける）
let fetch = ActionPattern<AppAction, Int>.case { if case .fetch(let id) = $0 { id } else { nil } }
let search = ActionPattern<AppAction, String>.case { if case .search(let q) = $0 { q } else { nil } }
let save = ActionPattern<AppAction, User>.case { if case .save(let user) = $0 { user } else { nil } }
let scrolled = ActionPattern<AppAction, Int>.case { if case .scrolled(let y) = $0 { y } else { nil } }
```

## Saga の定義（`function* saga() {}`）

```js
// redux-saga
function* userSaga() {
  yield takeLatest(FETCH, fetchUser)
}
```

```swift
// swift-redux-saga
struct UserSagas: Sendable {
  let api: UserAPI   // 依存は Saga を作るときに注入する

  var root: Saga<AppState, AppAction> {
    Saga("user") { ctx in
      ctx.takeLatest(fetch, fetchUser)
    }
  }

  func fetchUser(_ ctx: SagaContext<AppState, AppAction>, _ id: Int) async throws {
    await ctx.put(.fetched(try await ctx.call(api.fetch, id)))
  }
}
```

- `Saga(名前) { ctx in ... }` で作ります。名前はエラーの経路（`SagaError.sagaStack`）やモニタに出ます。
- 起動は `sagaMiddleware.run(userSagas.root)` です（テストでは `SagaTester` / `TestStore`）。
- 別の Saga を子として fork せずにその場で実行するには、`try await otherSaga.run(ctx)` と書きます（redux-saga の `yield* otherSaga()`）。

## take

```js
// redux-saga
const action = yield take(FETCH)
```

```swift
// swift-redux-saga
let id = try await ctx.take(fetch)          // パターンが取り出した値（ここでは ID）を返す
let action = try await ctx.take()           // 次に届く Action そのもの
_ = try await ctx.take(.action(.logout))    // 特定の Action（Action が Equatable のとき）
let any = try await ctx.take(.oneOf(.action(.login), .action(.logout)))   // いずれか
```

- 待ち始めてから届いた、パターンに一致する Action を 1 つ受け取ります。待ち始める前に届いた Action は受け取りません（redux-saga と同じ）。
- 処理中に届く Action も取りこぼしたくない場合は、`actionChannel` か `takeEvery` を使います。
- パターンは `ActionPattern` で作ります。`.case { ... }`（値を取り出す）、`.action(...)`（等しい Action）、`.filter { ... }`（条件）、`.oneOf(...)`（いずれか）、`.any`（すべて）、`.type(...)`（型で判定）があり、`.where { ... }` で条件を足せます。

## put

```js
// redux-saga
yield put({ type: FETCHED, user })
```

```swift
// swift-redux-saga
await ctx.put(.fetched(user))
```

- Action を発行します。Store の reducer で処理し終えてから戻るので、直後の `select` は更新後の State を返します。
- `put` は失敗しないので `try` は要りません。

## select

```js
// redux-saga
const token = yield select(state => state.token)
```

```swift
// swift-redux-saga
let token = await ctx.select(\.token)            // キーパス
let user = await ctx.select { $0.user }           // 関数
let state = await ctx.select()                    // State 全体
let visible = await ctx.select { visibleTodos($0) }   // createSelector で作ったセレクタ
```

- 呼んだ時点の State を返します。Store の State はメインアクターにあるので、`await` で取り出します。

## call

```js
// redux-saga
const user = yield call(api.fetchUser, id)
```

```swift
// swift-redux-saga
let user = try await ctx.call(api.fetch, id)
let users = try await ctx.call(api.search, "swift")
try await ctx.call { try await Task.sleep(for: .seconds(1)) }   // 引数のない関数やクロージャも渡せる
```

- 任意の async 関数を呼びます。引数の数と型は関数に合わせて型検査されます（パラメータパック）。
- `try await api.fetch(id)` と直接書くのとの違いは、キャンセルの扱いです。呼ぶ前と戻った後にキャンセルを確かめ、キャンセルされていれば結果やエラーを返さずに `CancellationError` を投げます。`takeLatest` で止めた古いリクエストの結果が、新しい結果を上書きしないようにするためです。
- 関数が投げたエラーはそのまま投げます。`do` / `catch` で受けて、失敗の Action にしてください（README の「エラー処理」）。

## fork / spawn

```js
// redux-saga
const task = yield fork(watchUser)
const detached = yield spawn(analyticsSaga)
```

```swift
// swift-redux-saga
let task = ctx.fork { ctx in
  // 子として動く Saga
  while true {
    let id = try await ctx.take(fetch)
    await ctx.put(.fetched(try await ctx.call(api.fetch, id)))
  }
}
let detached = ctx.spawn("analytics") { ctx in
  _ = try await ctx.take(.action(.logout))
}
```

- `fork` は子として起動し、待たずに続きを実行します（attached）。
  - 呼び出し元がキャンセルされると、子もキャンセルされます。
  - 子が失敗すると、兄弟と呼び出し元がキャンセルされ、エラーが呼び出し元に伝わります。
  - 呼び出し元の本体が終わっても、子がすべて終わるまで呼び出し元は完了しません。
- `spawn` は呼び出し元から切り離して起動します（detached）。呼び出し元のキャンセルや失敗の影響を受けず、子の失敗も呼び出し元に伝わりません。`sagaMiddleware.stop()` では止まります。
- どちらも、`Saga` を渡すこともできます（`ctx.fork(otherSagas.root)`）。
- 機能ごとのモジュールに分けた子の Saga を、子の State・Action の型のまま起動するには `ctx.fork(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)` を使います（README の「機能ごとの Store と Saga を組み合わせる」）。

## cancel / join

```js
// redux-saga
const task = yield fork(sync)
yield take(LOGOUT)
yield cancel(task)

const result = yield join(task)
```

```swift
// swift-redux-saga
let task = ctx.fork { ctx in
  while true {
    try await ctx.delay(.seconds(30))
    await ctx.put(.tick)
  }
}
_ = try await ctx.take(.action(.logout))
ctx.cancel(task)        // task.cancel() と同じ

let worker = ctx.fork { ctx in try await ctx.delay(.seconds(1)) }
try await ctx.join(worker)   // 終わるまで待つ
```

- `cancel` は子を止めます。fork した子を `cancel` しても、呼び出し元にエラーは伝わりません。止めた子の中では、待っている Effect が `CancellationError` を投げます。
- `join` は子が終わるまで待ちます。子が失敗した場合はそのエラーを、キャンセルされた場合は `CancellationError` を投げます。
- `SagaTask` は結果の値を持ちません。結果がほしい場合は、子の中で `put` するか、`all` / `race` を使います。
- キャンセルされたときの後始末（redux-saga の `finally { if (yield cancelled()) ... }`）は、`catch is CancellationError` で書きます。後始末の中で `put` もできます。

```swift
do {
  try await ctx.call(api.save, user)
} catch is CancellationError {
  await ctx.put(.failed("キャンセルされました"))   // 後始末
  throw CancellationError()                          // キャンセルとして終える
}
```

- `ctx.isCancelled` で、キャンセルされているかを確かめることもできます。

## delay

```js
// redux-saga
yield delay(1000)
```

```swift
// swift-redux-saga
try await ctx.delay(.seconds(1))
try await ctx.delay(.milliseconds(300))
```

- ランタイムに渡した `Clock` で待ちます。テストでは `TestClock` を使うので、実際の時間を待たずに `await tester.advance(by: .seconds(1))` で進められます。
- `Task.sleep` を直接呼ぶと `TestClock` で進められないので、Saga の中では `ctx.delay` を使ってください。

## takeEvery / takeLatest / takeLeading

```js
// redux-saga
yield takeEvery(SAVE, saveUser)       // すべて並行に処理
yield takeLatest(SEARCH, searchUsers) // 最後のリクエストだけ
yield takeLeading(LOGIN, login)       // 処理中は無視
```

```swift
// swift-redux-saga
ctx.takeEvery(save) { ctx, user in
  try await ctx.call(api.save, user)
  await ctx.put(.saved)
}
ctx.takeLatest(search) { ctx, query in
  await ctx.put(.results(try await ctx.call(api.search, query)))
}
ctx.takeLeading(.action(.login)) { ctx, _ in
  // ボタンの二重押しを防ぐ
}
```

- `takeEvery`: 一致する Action が届くたびにワーカーを起動します。ワーカーは並行に動き、処理中に届いた Action も取りこぼしません。
- `takeLatest`: 新しい Action が届くと、実行中のワーカーをキャンセルしてから起動します。検索の入力のように、最後のリクエストの結果だけが必要な場合に使います。
- `takeLeading`: ワーカーの実行中に届いた Action は無視します。二重送信を防ぎたい場合に使います。
- どれも呼び出した時点で購読を始め、待たずに続きを実行します（`yield` の代わりの `await` は要りません）。戻り値の `SagaTask` で止められます。
- ワーカーは別に定義した関数を名前で渡すこともできます（README の Saga の節）。
- ワーカーで処理しなかったエラーは、ヘルパーごと終了させ、呼び出し元に伝わります。続けたい場合はワーカーの中で `catch` してください。

## debounce / throttle

```js
// redux-saga
yield debounce(300, SEARCH, searchUsers)
yield throttle(500, SCROLLED, loadMore)
```

```swift
// swift-redux-saga
ctx.debounce(.milliseconds(300), search) { ctx, query in
  await ctx.put(.results(try await ctx.call(api.search, query)))
}
ctx.throttle(.milliseconds(500), scrolled) { ctx, offset in
  // スクロールに合わせて続きを読み込む
}
```

- `debounce`: Action が `duration` のあいだ届かなくなってから、最後の Action でワーカーを起動します。文字入力が止まってから 1 回だけ検索する場合に使います。起動したワーカーは、後から届いた Action ではキャンセルされません。
- `throttle`: ワーカーを起動した後、`duration` のあいだに届いた Action は最後の 1 つだけを残し、`duration` が過ぎてから処理します。頻繁に届く Action を間引く場合に使います。
- どちらも `TestClock` で時間を進めてテストできます。

## all / race

```js
// redux-saga
const [user, results] = yield all([
  call(api.fetchUser, id),
  call(api.search, query),
])

const { response, timeout } = yield race({
  response: call(api.fetchUser, id),
  timeout: delay(5000),
})
```

```swift
// swift-redux-saga
let (user, results) = try await ctx.all(
  { ctx in try await ctx.call(api.fetch, id) },
  { ctx in try await ctx.call(api.search, query) }
)

let (response, timeout): (User?, Void?) = try await ctx.race(
  { ctx in try await ctx.call(api.fetch, id) },
  { ctx in try await ctx.delay(.seconds(5)) }
)
if timeout != nil {
  await ctx.put(.failed("タイムアウト"))
} else if let response {
  await ctx.put(.fetched(response))
}
```

- `all`: すべての処理を並行に実行し、すべての結果をタプルで返します。1 つでも失敗すると残りをキャンセルしてそのエラーを投げ、1 つでもキャンセルで終わると残りをキャンセルして `CancellationError` を投げます。
- `race`: 最初に終わった処理の結果だけが値を持ち、残りは `nil` のタプルを返します。負けた処理はキャンセルします。最初に終わった処理が失敗した場合はそのエラーを投げます。
- 各処理は子として fork され、それぞれの `ctx` を受け取ります。処理の中で `take` も使えます（例: `{ ctx in try await ctx.take(.action(.logout)) }` で「ログアウトされたら中断」）。
- 処理の数と結果の型は、タプルで型検査されます（パラメータパック）。

## actionChannel

```js
// redux-saga
const channel = yield actionChannel(SAVE)
while (true) {
  const action = yield take(channel)
  yield call(saveUser, action)   // 1 件ずつ順に処理する
}
```

```swift
// swift-redux-saga
let saves = ctx.actionChannel(save)
for try await user in saves {
  try await ctx.call(api.save, user)   // 1 件ずつ順に処理する
  await ctx.put(.saved)
}
```

- 作った時点から、パターンに一致する Action を溜めます。処理中に届いた Action も取りこぼさずに、届いた順に 1 件ずつ処理できます。
- バッファの方式は `buffer:` で選べます（`.unbounded`（既定）、`.newest(n)`、`.oldest(n)`）。
- 作った Saga が終わると、チャネルは自動で閉じて購読をやめます（redux-saga では明示的に閉じる必要があります）。`close()` で先に閉じることもできます。
- 複数の Saga から読むと、値は待ち始めた順に 1 つずつ渡されます（ワーカープール）。

## eventChannel

```js
// redux-saga
function countdown(seconds) {
  return eventChannel(emit => {
    const timer = setInterval(() => emit(seconds--), 1000)
    return () => clearInterval(timer)
  })
}
const channel = yield call(countdown, 10)
while (true) {
  const seconds = yield take(channel)
}
```

```swift
// swift-redux-saga（購読関数で作る）
let ticks = ctx.eventChannel(buffer: .newest(1)) { (emit: @escaping @Sendable (Date) -> Void, finish) in
  let task = Task {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      emit(Date())
    }
  }
  return { task.cancel() }   // 閉じたときに購読を解除する（解除する関数は Sendable にする）
}
for try await _ in ticks {
  await ctx.put(.tick)
}

// swift-redux-saga（AsyncSequence から作る）
let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
for try await message in ctx.eventChannel(from: stream) {
  // WebSocket などのメッセージを 1 件ずつ処理する
}
```

- 外部のイベント源（タイマー、通知、WebSocket など）の値を、Saga で 1 件ずつ受け取ります。
- 購読関数は、値を入れる `emit` と、終わりを伝える `finish` を受け取り、購読を解除する関数を返します。チャネルが閉じられたとき（作った Saga が終わったとき）に呼ばれます。
- イベント源が障害で終わった場合は `finish(throwing: error)` を呼ぶと、受け取り側（`for try await`）が溜まっている値の後にそのエラーを投げます。正常終了（`finish()`）と区別して、再接続などを書けます。`eventChannel(from:)` では、シーケンスのエラーがそのまま伝わります。
