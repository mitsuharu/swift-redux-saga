# Saga の Effect

Saga の中で使う Effect（`take` / `put` / `call` など）を、1 つずつ説明します。各節は「何をするか」「Swift での書き方」の順で、最後に「redux-saga では」として、JavaScript の redux-saga で同じことをどう書くかを比べます。redux-saga を知らなくても、最初の 2 つだけで読めます。

- Saga は、`SagaContext`（以下 `ctx`）を受け取る async 関数です。Effect はすべて `ctx` のメソッドで、`await` で呼びます。
- 待つ Effect（`take` / `call` / `delay` / `join` など）は、Saga がキャンセルされると `CancellationError` を投げます。
- 一覧だけ見たい場合は、[README の対応表](../README.md#saga)を見てください。

## 目次

- [例で使う型](#例で使う型)
- [Saga — 処理の流れを書く単位](#saga--処理の流れを書く単位)
- [take — Action が届くまで待つ](#take--action-が届くまで待つ)
- [put — Action を発行する](#put--action-を発行する)
- [select — State を読む](#select--state-を読む)
- [call — 関数を呼ぶ（通信など）](#call--関数を呼ぶ通信など)
- [fork / spawn — 別の処理を並行に起動する](#fork--spawn--別の処理を並行に起動する)
- [cancel / join — 起動した処理を止める、終わるまで待つ](#cancel--join--起動した処理を止める終わるまで待つ)
- [delay — 指定した時間だけ待つ](#delay--指定した時間だけ待つ)
- [takeEvery / takeLatest / takeLeading — Action が届くたびに処理を起動する](#takeevery--takelatest--takeleading--action-が届くたびに処理を起動する)
- [debounce / throttle — 頻繁に届く Action をまとめる、間引く](#debounce--throttle--頻繁に届く-action-をまとめる間引く)
- [all / race — 複数の処理を並行に実行する](#all--race--複数の処理を並行に実行する)
- [actionChannel — Action を溜めて 1 件ずつ処理する](#actionchannel--action-を溜めて-1-件ずつ処理する)
- [eventChannel — 外部のイベントを Saga で受け取る](#eventchannel--外部のイベントを-saga-で受け取る)

## 例で使う型

以降の例は、次の型を使います。通信などのビジネスロジック（`UserAPI`）は、本ライブラリに依存しません。

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

## Saga — 処理の流れを書く単位

**何をするか**: Action を受けてビジネスロジックを呼び、結果を Action で返す、という処理の流れを書く単位です。Store の外で動き、通信のような時間のかかる処理や、複数の Action にまたがる流れ（ログインしてから読み込む、など）を受け持ちます。

**Swift での書き方**: `Saga(名前) { ctx in ... }` で作ります。依存（`UserAPI` など）は、Saga を作るときに注入します。

```swift
struct UserSagas: Sendable {
  let api: UserAPI

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

- 起動は `sagaMiddleware.run(userSagas.root)` です（テストでは `SagaTester` / `TestStore`）。
- 名前は、エラーの経路（`SagaError.sagaStack`）やモニタに出ます。
- 別の Saga を、子として起動せずにその場で実行するには `try await otherSaga.run(ctx)` と書きます。

**redux-saga では**: ジェネレーター関数（`function*`）で書いていたものが、`ctx` を受け取る async 関数になります。`yield` の代わりに `await` で Effect を呼びます。

```js
function* userSaga() {
  yield takeLatest(FETCH, fetchUser)
}
// yield* otherSaga() → try await otherSaga.run(ctx)
```

## take — Action が届くまで待つ

**何をするか**: 指定した Action が届くまで待ち、届いた Action（から取り出した値）を返します。「ログインされるまで待つ」「次の検索語を受け取る」のように、流れの途中で Action を待つときに使います。

**Swift での書き方**: どの Action を待つかは `ActionPattern` で指定します。

```swift
let id = try await ctx.take(fetch)          // .fetch(id) を待ち、ID を受け取る
let action = try await ctx.take()           // 次に届く Action をそのまま受け取る
_ = try await ctx.take(.action(.logout))    // 特定の Action（Action が Equatable のとき）
let next = try await ctx.take(.oneOf(.action(.login), .action(.logout)))   // いずれか
```

- 待ち始めてから届いた Action だけを受け取ります。待ち始める前や、ほかの処理をしている間に届いた Action は受け取りません。取りこぼしたくない場合は、`actionChannel` か `takeEvery` を使います。
- パターンには、`.case { ... }`（値を取り出す）、`.action(...)`（等しい Action）、`.filter { ... }`（条件）、`.oneOf(...)`（いずれか）、`.any`（すべて）、`.type(...)`（型で判定）があり、`.where { ... }` で条件を足せます。

**redux-saga では**: `yield take(FETCH)` が `try await ctx.take(fetch)` になります。Action の type の文字列の代わりに、パターンで Action を選び、関連値を型付きで受け取ります。

```js
const action = yield take(FETCH)
const id = action.payload
```

## put — Action を発行する

**何をするか**: Action を発行して、Store（reducer）に State を更新させます。通信の結果を State に反映するときなどに使います。

**Swift での書き方**:

```swift
await ctx.put(.fetched(user))
```

- reducer が処理し終えてから戻ります。直後の `select` は、更新後の State を返します。
- 失敗しないので `try` は要りません。

**redux-saga では**: `yield put({ type: FETCHED, user })` が `await ctx.put(.fetched(user))` になります。Action は enum の case で作ります。

```js
yield put({ type: FETCHED, user })
```

## select — State を読む

**何をするか**: 今の State を読みます。保存してあるトークンを使って通信する、今の値によって処理を変える、といったときに使います。

**Swift での書き方**:

```swift
let token = await ctx.select(\.token)             // キーパスで一部を読む
let user = await ctx.select { $0.user }            // 関数で読む
let state = await ctx.select()                     // State 全体
let visible = await ctx.select { visibleTodos($0) }   // createSelector で作ったセレクタ
```

- 呼んだ時点の State を返します。Store の State はメインアクターにあるので、`await` で読みます。

**redux-saga では**: `yield select(state => state.token)` が `await ctx.select(\.token)` になります。

```js
const token = yield select(state => state.token)
```

## call — 関数を呼ぶ（通信など）

**何をするか**: async 関数（通信、データベース、ファイルなど、ビジネスロジックの関数）を呼び、結果を受け取ります。

**Swift での書き方**: 関数と引数を渡します。

```swift
let user = try await ctx.call(api.fetch, id)
let users = try await ctx.call(api.search, "swift")
try await ctx.call { try await Task.sleep(for: .seconds(1)) }   // 引数のない関数やクロージャも渡せる
```

- 引数の数と型は、関数に合わせて型検査されます。
- `try await api.fetch(id)` と直接書くこともできますが、`call` を使うとキャンセルを正しく扱えます。呼ぶ前と戻った後にキャンセルを確かめ、キャンセルされていれば、結果やエラーを返さずに `CancellationError` を投げます。`takeLatest` で止めた古いリクエストの結果が、新しい結果を上書きしないようにするためです。
- 関数が投げたエラーはそのまま投げます。`do` / `catch` で受けて、失敗の Action にしてください（README の「エラー処理」）。

**redux-saga では**: `yield call(api.fetchUser, id)` が `try await ctx.call(api.fetch, id)` になります。関数と引数を分けて渡す点は同じです。

```js
const user = yield call(api.fetchUser, id)
```

## fork / spawn — 別の処理を並行に起動する

**何をするか**: 別の処理（Saga）を起動し、その終わりを待たずに続きを実行します。Action を待ち続ける監視の処理を、いくつも同時に動かすときなどに使います。

- `fork`: 呼び出し元の**子**として起動します。呼び出し元と運命を共にします。
  - 呼び出し元がキャンセルされると、子もキャンセルされます。
  - 子が失敗すると、兄弟と呼び出し元がキャンセルされ、エラーが呼び出し元に伝わります。
  - 呼び出し元は、子がすべて終わるまで完了しません。
- `spawn`: 呼び出し元から**切り離して**起動します。呼び出し元のキャンセルや失敗の影響を受けず、子の失敗も呼び出し元に伝わりません。`sagaMiddleware.stop()` では止まります。

**Swift での書き方**: 戻り値の `SagaTask` で、後から止めたり（`cancel`）待ったり（`join`）できます。

```swift
let task = ctx.fork { ctx in
  // 子として動く処理
  while true {
    let id = try await ctx.take(fetch)
    await ctx.put(.fetched(try await ctx.call(api.fetch, id)))
  }
}
let detached = ctx.spawn("analytics") { ctx in
  _ = try await ctx.take(.action(.logout))
}
```

- クロージャの代わりに、`Saga` を渡すこともできます（`ctx.fork(otherSagas.root)`）。
- 機能ごとのモジュールに分けた Saga を、その State・Action の型のまま子として起動するには、`ctx.fork(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)` と書きます（README の「機能ごとの Store と Saga を組み合わせる」）。

**redux-saga では**: `yield fork(saga)` / `yield spawn(saga)` が `ctx.fork(...)` / `ctx.spawn(...)` になります。待たないので `await` は付けません。親子の関係（attached / detached）の意味は redux-saga と同じです。

```js
const task = yield fork(watchUser)
const detached = yield spawn(analyticsSaga)
```

## cancel / join — 起動した処理を止める、終わるまで待つ

**何をするか**:

- `cancel`: `fork` / `spawn` で起動した処理を止めます。ログアウトで同期の処理を止める、といったときに使います。止めた処理の中では、待っている Effect が `CancellationError` を投げます。fork した子を止めても、呼び出し元にエラーは伝わりません。
- `join`: 起動した処理が終わるまで待ちます。処理が失敗した場合はそのエラーを、キャンセルされた場合は `CancellationError` を投げます。

**Swift での書き方**:

```swift
let sync = ctx.fork { ctx in
  while true {
    try await ctx.delay(.seconds(30))
    await ctx.put(.tick)
  }
}
_ = try await ctx.take(.action(.logout))
ctx.cancel(sync)             // sync.cancel() と同じ

let worker = ctx.fork { ctx in try await ctx.delay(.seconds(1)) }
try await ctx.join(worker)   // 終わるまで待つ
```

- `SagaTask` は結果の値を持ちません。結果がほしい場合は、子の中で `put` するか、`all` / `race` を使います。
- キャンセルされたときの後始末は、`catch is CancellationError` で書きます。後始末の中で `put` もできます。`ctx.isCancelled` で、キャンセルされているかを確かめることもできます。

```swift
do {
  try await ctx.call(api.save, user)
} catch is CancellationError {
  await ctx.put(.failed("キャンセルされました"))   // 後始末
  throw CancellationError()                          // キャンセルとして終える
}
```

**redux-saga では**: `yield cancel(task)` が `ctx.cancel(task)`、`yield join(task)` が `try await ctx.join(task)` になります。後始末を `finally { if (yield cancelled()) ... }` で書いていたところは、`catch is CancellationError` で書きます。

```js
const task = yield fork(sync)
yield take(LOGOUT)
yield cancel(task)

try {
  yield call(api.save, user)
} finally {
  if (yield cancelled()) { yield put({ type: FAILED }) }
}
```

## delay — 指定した時間だけ待つ

**何をするか**: 指定した時間だけ待ちます。一定の間隔で処理を繰り返す（ポーリング）、時間をおいて再試行する、といったときに使います。

**Swift での書き方**: 時間は `Duration` で指定します。

```swift
try await ctx.delay(.seconds(1))
try await ctx.delay(.milliseconds(300))
```

- ランタイムに渡した `Clock` で待ちます。テストでは `TestClock` を使うので、実際の時間を待たずに `await tester.advance(by: .seconds(1))` で進められます。
- `Task.sleep` を直接呼ぶと、テストで時間を進められないので、Saga の中では `ctx.delay` を使ってください。

**redux-saga では**: ミリ秒の数値で書いていた `yield delay(1000)` が、`try await ctx.delay(.seconds(1))` になります。

```js
yield delay(1000)
```

## takeEvery / takeLatest / takeLeading — Action が届くたびに処理を起動する

**何をするか**: 指定した Action が届くたびに、処理（ワーカー）を起動します。「保存ボタンが押されたら保存する」のように、Action と処理を結びつけるときの基本の書き方です。3 つは、処理中に次の Action が届いたときの扱いが違います。

| 関数 | 処理中に次の Action が届いたら | 向いている場面 |
| --- | --- | --- |
| `takeEvery` | もう 1 つ起動する（並行に動く） | 保存や削除など、どれも処理したいとき |
| `takeLatest` | 処理中のものをキャンセルして、新しく起動する | 検索など、最後の結果だけがほしいとき |
| `takeLeading` | 無視する | ボタンの二重押しを防ぎたいとき |

**Swift での書き方**: ワーカーは `(ctx, パターンが取り出した値)` を受け取るクロージャか、同じ形の関数です。

```swift
ctx.takeEvery(save) { ctx, user in
  try await ctx.call(api.save, user)
  await ctx.put(.saved)
}
ctx.takeLatest(search) { ctx, query in
  await ctx.put(.results(try await ctx.call(api.search, query)))
}
ctx.takeLeading(.action(.login)) { ctx, _ in
  // ログインの処理
}
```

- どれも呼び出した時点で Action の受け取りを始め、待たずに続きを実行します（`await` は付けません）。処理中に届いた Action も取りこぼしません。戻り値の `SagaTask` で止められます。
- ワーカーは、別に定義した関数を名前で渡すこともできます（README の Saga の節）。
- ワーカーで処理しなかったエラーは、ヘルパーごと終了させ、呼び出し元に伝わります。続けたい場合は、ワーカーの中で `catch` してください。

**redux-saga では**: `yield takeEvery(SAVE, saveUser)` が `ctx.takeEvery(save, saveUser)` になります。3 つの意味は redux-saga と同じです。

```js
yield takeEvery(SAVE, saveUser)
yield takeLatest(SEARCH, searchUsers)
yield takeLeading(LOGIN, login)
```

## debounce / throttle — 頻繁に届く Action をまとめる、間引く

**何をするか**: 文字入力やスクロールのように、短い間隔で何度も届く Action を、毎回処理せずに済ませます。

- `debounce`: Action が指定した時間だけ届かなくなってから、最後の Action で 1 回だけ処理します。文字入力が止まってから検索する、といったときに使います。
- `throttle`: 処理した後、指定した時間のあいだに届いた Action は最後の 1 つだけを残し、時間が過ぎてから処理します。スクロールに合わせた読み込みを間引く、といったときに使います。

**Swift での書き方**: 最初の引数に時間を渡します。

```swift
ctx.debounce(.milliseconds(300), search) { ctx, query in
  await ctx.put(.results(try await ctx.call(api.search, query)))
}
ctx.throttle(.milliseconds(500), scrolled) { ctx, offset in
  // スクロールに合わせて続きを読み込む
}
```

- `debounce` で起動した処理は、後から届いた Action ではキャンセルされません。
- どちらも `TestClock` で時間を進めてテストできます。

**redux-saga では**: ミリ秒の数値で書いていた `yield debounce(300, SEARCH, search)` が、`ctx.debounce(.milliseconds(300), search) { ... }` になります。

```js
yield debounce(300, SEARCH, searchUsers)
yield throttle(500, SCROLLED, loadMore)
```

## all / race — 複数の処理を並行に実行する

**何をするか**:

- `all`: 複数の処理を同時に始め、すべてが終わるのを待って、すべての結果を受け取ります。プロフィールと投稿を同時に読み込む、といったときに使います。1 つでも失敗（またはキャンセル）すると、残りを止めてエラーを投げます。
- `race`: 複数の処理を同時に始め、最初に終わったものの結果だけを受け取ります。残りは止めます。通信にタイムアウトを付ける、ログアウトされたら中断する、といったときに使います。

**Swift での書き方**: 処理を `{ ctx in ... }` で並べます。結果はタプルで受け取ります。

```swift
// all: すべての結果
let (user, results) = try await ctx.all(
  { ctx in try await ctx.call(api.fetch, id) },
  { ctx in try await ctx.call(api.search, query) }
)

// race: 最初に終わったものだけが値を持つ（残りは nil）
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

- 処理はそれぞれ子として起動され、自分の `ctx` を受け取ります。処理の中で `take` も使えます（例: `{ ctx in try await ctx.take(.action(.logout)) }` を `race` に並べると「ログアウトされたら中断」）。
- `race` で最初に終わった処理が失敗した場合は、そのエラーを投げます。
- 処理の数と結果の型は、タプルで型検査されます。

**redux-saga では**: 配列で渡していた `all([...])` は、処理を引数に並べてタプルで受け取る形になります。オブジェクトのキーで受け取っていた `race({ response, timeout })` は、並べた順のタプル（勝ったものだけが nil でない）で受け取ります。

```js
const [user, results] = yield all([
  call(api.fetchUser, id),
  call(api.search, query),
])

const { response, timeout } = yield race({
  response: call(api.fetchUser, id),
  timeout: delay(5000),
})
```

## actionChannel — Action を溜めて 1 件ずつ処理する

**何をするか**: 指定した Action を溜めておき、届いた順に 1 件ずつ取り出して処理します。保存を 1 件ずつ順に行いたい（同時に保存すると順序が崩れる）ときに使います。`take` と違い、処理中に届いた Action も溜まるので取りこぼしません。

**Swift での書き方**: 作ったチャネルを `for try await` で読みます。

```swift
let saves = ctx.actionChannel(save)
for try await user in saves {
  try await ctx.call(api.save, user)   // 1 件ずつ順に処理する
  await ctx.put(.saved)
}
```

- 溜め方は `buffer:` で選べます（`.unbounded`（既定、すべて溜める）、`.newest(n)`（新しい n 件）、`.oldest(n)`（古い n 件））。
- 作った Saga が終わると、チャネルは自動で閉じて受け取りをやめます。`close()` で先に閉じることもできます。
- 複数の Saga から読むと、値は待ち始めた順に 1 つずつ渡されます（同じ処理を複数で分担する）。

**redux-saga では**: `yield actionChannel(SAVE)` と `while (true) { yield take(channel) }` の組み合わせが、`ctx.actionChannel(save)` と `for try await` になります。redux-saga では明示的に閉じる必要がありましたが、作った Saga の終わりで自動的に閉じます。

```js
const channel = yield actionChannel(SAVE)
while (true) {
  const action = yield take(channel)
  yield call(saveUser, action)
}
```

## eventChannel — 外部のイベントを Saga で受け取る

**何をするか**: タイマー、通知、WebSocket など、Action ではない外部のイベントを、Saga で 1 件ずつ受け取れるようにします。

**Swift での書き方**: 2 つの作り方があります。

```swift
// 1. 購読する関数で作る: emit で値を入れ、購読を解除する関数を返す
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

// 2. AsyncSequence（AsyncStream など）から作る
let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
for try await message in ctx.eventChannel(from: stream) {
  // WebSocket などのメッセージを 1 件ずつ処理する
}
```

- 購読を解除する関数は、チャネルが閉じられたとき（作った Saga が終わったとき）に呼ばれます。
- イベント源が障害で終わった場合は `finish(throwing: error)` を呼ぶと、受け取り側（`for try await`）が、溜まっている値を受け取った後にそのエラーを投げます。正常な終わり（`finish()`）と区別できるので、再接続などを書けます。`eventChannel(from:)` では、シーケンスのエラーがそのまま伝わります。

**redux-saga では**: `eventChannel(emit => { ...; return unsubscribe })` の形はそのままで、`emit` に加えて終わりを伝える `finish` を受け取ります。`yield take(channel)` のループは `for try await` になります。

```js
const channel = eventChannel(emit => {
  const timer = setInterval(() => emit(new Date()), 1000)
  return () => clearInterval(timer)
})
while (true) {
  yield take(channel)
  yield put({ type: TICK })
}
```
