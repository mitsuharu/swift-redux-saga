# Saga の Effect

この章では、Saga の中で使う Effect（`take`、`put`、`call` など）を 1 つずつ説明します。各節では、まずその Effect が何をするものかを説明し、Swift での書き方を示します。節の終わりでは、JavaScript の redux-saga で同じことをどう書いていたかと比べます。redux-saga を知らない場合は、比較の部分は読み飛ばしてかまいません。

Saga は、`SagaContext`（以下 `ctx`）を受け取る async 関数です。Effect はすべて `ctx` のメソッドで、`await` を付けて呼びます。Saga がキャンセルされると、`take` や `call`、`delay` のように待つ Effect は `CancellationError` を投げます。

Effect の一覧だけを見たい場合は、[README の対応表](../README.md#saga)を参照してください。

## 目次

1. [例で使う型](#例で使う型)
2. [Saga を定義する](#saga-を定義する)
3. [take: Action が届くまで待つ](#take-action-が届くまで待つ)
4. [put: Action を発行する](#put-action-を発行する)
5. [select: State を読む](#select-state-を読む)
6. [call: 関数を呼ぶ](#call-関数を呼ぶ)
7. [fork と spawn: 処理を並行に起動する](#fork-と-spawn-処理を並行に起動する)
8. [cancel と join: 起動した処理を止める、待つ](#cancel-と-join-起動した処理を止める待つ)
9. [delay: 時間を置く](#delay-時間を置く)
10. [takeEvery、takeLatest、takeLeading: Action ごとに処理を起動する](#takeeverytakelatesttakeleading-action-ごとに処理を起動する)
11. [debounce と throttle: 頻繁な Action をまとめる](#debounce-と-throttle-頻繁な-action-をまとめる)
12. [all と race: 複数の処理を並行に実行する](#all-と-race-複数の処理を並行に実行する)
13. [actionChannel: Action を溜めて順に処理する](#actionchannel-action-を溜めて順に処理する)
14. [eventChannel: 外部のイベントを受け取る](#eventchannel-外部のイベントを受け取る)

## 例で使う型

この章の例は、すべて次の型を使います。ユーザーを取得・検索・保存する `UserAPI` はビジネスロジックの側に置き、本ライブラリには依存させません。

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

## Saga を定義する

Saga は、Action を受けてビジネスロジックを呼び、その結果を Action として返す処理の流れを書く場所です。Store の外で動くので、通信のように時間のかかる処理や、「ログインしてから一覧を読み込む」のように複数の Action にまたがる流れを受け持たせます。

Saga は `Saga(名前) { ctx in ... }` で作ります。次の例では、`UserSagas` が依存する `UserAPI` を、作るときに受け取っています。

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

作った Saga は `sagaMiddleware.run(userSagas.root)` で起動します。テストでは `SagaTester` や `TestStore` に渡します。Saga に付けた名前は、エラーが伝わった経路（`SagaError.sagaStack`）やモニタの出力に使われます。別の Saga を子として起動せずに、その場で続けて実行したいときは `try await otherSaga.run(ctx)` と書きます。

redux-saga ではジェネレーター関数（`function*`）で Saga を書き、`yield` で Effect を呼んでいました。swift-redux-saga では、これが `ctx` を受け取る async 関数と `await` に置き換わります。`yield* otherSaga()` に当たるのが `try await otherSaga.run(ctx)` です。

```js
function* userSaga() {
  yield takeLatest(FETCH, fetchUser)
}
```

## take: Action が届くまで待つ

`take` は、指定した Action が届くまで Saga を止めて待ちます。届くと、その Action（またはそこから取り出した値）を返します。「ログインされるまで待つ」「次の検索語を受け取る」のように、流れの途中で Action を待つときに使います。

どの Action を待つかは `ActionPattern` で指定します。

```swift
let id = try await ctx.take(fetch)          // .fetch(id) を待ち、ID を受け取る
let action = try await ctx.take()           // 次に届く Action をそのまま受け取る
_ = try await ctx.take(.action(.logout))    // 特定の Action を待つ（Action が Equatable のとき）
let next = try await ctx.take(.oneOf(.action(.login), .action(.logout)))   // いずれかを待つ
```

パターンには、関連値を取り出す `.case { ... }` のほか、等しい Action に一致する `.action(...)`、条件で選ぶ `.filter { ... }`、いずれかに一致する `.oneOf(...)`、すべてに一致する `.any`、型で判定する `.type(...)` があります。`.where { ... }` を付けると条件を足せます。

`take` が受け取るのは、待ち始めてから届いた Action だけです。待ち始める前や、ほかの処理をしている間に届いた Action は受け取りません。取りこぼしたくない場合は、後で説明する `actionChannel` や `takeEvery` を使います。

redux-saga の `yield take(FETCH)` に当たります。redux-saga では type の文字列で Action を選び、`action.payload` から値を取り出していましたが、swift-redux-saga ではパターンで Action を選び、関連値を型付きのまま受け取ります。

```js
const action = yield take(FETCH)
const id = action.payload
```

## put: Action を発行する

`put` は Action を発行し、Store の reducer に State を更新させます。通信で受け取った結果を State に反映するときなどに使います。

```swift
await ctx.put(.fetched(user))
```

`put` は reducer が処理を終えてから戻るので、直後に `select` で読むと、更新後の State が得られます。失敗することはないため、`try` は要りません。

redux-saga の `yield put({ type: FETCHED, user })` に当たります。Action はオブジェクトではなく、enum の case で作ります。

```js
yield put({ type: FETCHED, user })
```

## select: State を読む

`select` は、今の State を読みます。保存してあるトークンを使って通信する、今の値によって処理を分ける、といったときに使います。

```swift
let token = await ctx.select(\.token)                  // キーパスで一部を読む
let user = await ctx.select { $0.user }                 // 関数で読む
let state = await ctx.select()                          // State 全体を読む
let visible = await ctx.select { visibleTodos($0) }     // createSelector で作ったセレクタを使う
```

返すのは、呼んだ時点の State です。Store の State はメインアクターにあるので、`await` を付けて読みます。

redux-saga の `yield select(state => state.token)` に当たります。

```js
const token = yield select(state => state.token)
```

## call: 関数を呼ぶ

`call` は、async 関数を呼んで結果を受け取ります。通信やデータベース、ファイルの読み書きなど、ビジネスロジックの関数を呼ぶときに使います。関数と引数を分けて渡し、引数の数と型は関数に合わせて型検査されます。

```swift
let user = try await ctx.call(api.fetch, id)
let users = try await ctx.call(api.search, "swift")
try await ctx.call { try await Task.sleep(for: .seconds(1)) }   // 引数のない関数やクロージャも渡せる
```

`try await api.fetch(id)` と直接書くこともできますが、`call` を通すとキャンセルを正しく扱えます。`call` は関数を呼ぶ前と戻った後にキャンセルを確かめ、キャンセルされていれば、結果やエラーを返さずに `CancellationError` を投げます。たとえば `takeLatest` で止めた古いリクエストの結果が、後から新しい結果を上書きすることを防げます。

関数が投げたエラーは、そのまま投げ直します。`do` / `catch` で受けて、失敗を表す Action にしてください（README の「エラー処理」を参照）。

redux-saga の `yield call(api.fetchUser, id)` に当たります。関数と引数を分けて渡す点は同じです。

```js
const user = yield call(api.fetchUser, id)
```

## fork と spawn: 処理を並行に起動する

`fork` と `spawn` は、別の処理を起動し、その終わりを待たずに続きを実行します。Action を待ち続ける監視の処理をいくつも同時に動かす、といったときに使います。

`fork` は、呼び出し元の子として処理を起動します。子は呼び出し元と運命を共にし、呼び出し元がキャンセルされると子もキャンセルされます。子が失敗すると、兄弟と呼び出し元もキャンセルされ、エラーが呼び出し元に伝わります。また、呼び出し元は子がすべて終わるまで完了しません。

一方の `spawn` は、呼び出し元から切り離して処理を起動します。呼び出し元がキャンセルされても失敗しても影響を受けず、子の失敗も呼び出し元には伝わりません。ただし、`sagaMiddleware.stop()` では止まります。

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

どちらも、起動した処理を表す `SagaTask` を返します。これを使って、後から処理を止めたり（`cancel`）、終わるまで待ったり（`join`）できます。クロージャの代わりに `Saga` を渡すこともできます（`ctx.fork(otherSagas.root)`）。機能ごとのモジュールに分けた Saga を、その State と Action の型のまま子として起動する方法は、README の「機能ごとの Store と Saga を組み合わせる」で説明しています。

redux-saga の `yield fork(saga)` と `yield spawn(saga)` に当たります。どちらも待たない Effect なので、`await` は付けません。子として結び付く（attached）か、切り離す（detached）かの意味は redux-saga と同じです。

```js
const task = yield fork(watchUser)
const detached = yield spawn(analyticsSaga)
```

## cancel と join: 起動した処理を止める、待つ

`fork` や `spawn` で起動した処理は、`cancel` で止められます。ログアウトしたら同期の処理を止める、といった使い方です。止められた処理の中では、待っていた Effect が `CancellationError` を投げます。fork した子を止めても、呼び出し元にエラーは伝わりません。

起動した処理が終わるまで待つには、`join` を使います。処理が失敗した場合は、`join` がそのエラーを投げます。キャンセルされた場合は `CancellationError` を投げます。

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

`SagaTask` は結果の値を持ちません。起動した処理の結果がほしい場合は、子の中で `put` するか、後で説明する `all` や `race` を使います。

キャンセルされたときに後始末をしたい場合は、`catch is CancellationError` で受けます。後始末の中で `put` することもできます。キャンセルされているかどうかは、`ctx.isCancelled` でも確かめられます。

```swift
do {
  try await ctx.call(api.save, user)
} catch is CancellationError {
  await ctx.put(.failed("キャンセルされました"))   // 後始末
  throw CancellationError()                          // キャンセルとして終える
}
```

redux-saga の `yield cancel(task)` と `yield join(task)` に当たります。redux-saga では後始末を `finally` の中で `yield cancelled()` を確かめて書いていましたが、swift-redux-saga では `catch is CancellationError` で書きます。

```js
const task = yield fork(sync)
yield take(LOGOUT)
yield cancel(task)

try {
  yield call(api.save, user)
} finally {
  if (yield cancelled()) {
    yield put({ type: FAILED })
  }
}
```

## delay: 時間を置く

`delay` は、指定した時間だけ待ちます。一定の間隔で処理を繰り返したり（ポーリング）、時間を置いてから再試行したりするときに使います。時間は `Duration` で指定します。

```swift
try await ctx.delay(.seconds(1))
try await ctx.delay(.milliseconds(300))
```

`delay` は、ランタイムに渡した `Clock` で待ちます。テストでは `TestClock` を渡すので、実際の時間を待たずに `await tester.advance(by: .seconds(1))` で時間を進められます。`Task.sleep` を直接呼ぶとテストで時間を進められなくなるので、Saga の中では `ctx.delay` を使ってください。

redux-saga の `yield delay(1000)` に当たります。ミリ秒の数値の代わりに `.seconds(1)` のように書きます。

```js
yield delay(1000)
```

## takeEvery、takeLatest、takeLeading: Action ごとに処理を起動する

この 3 つは、指定した Action が届くたびに処理（ワーカー）を起動します。「保存ボタンが押されたら保存する」のように、Action と処理を結び付けるときの基本の書き方です。

3 つの違いは、処理中に次の Action が届いたときの扱いにあります。`takeEvery` はもう 1 つ処理を起動し、両方を並行に動かします。保存や削除のように、届いたものをすべて処理したいときに使います。`takeLatest` は処理中のものをキャンセルしてから新しく起動します。検索のように、最後の結果だけがあればよいときに使います。`takeLeading` は処理中に届いた Action を無視します。ボタンの二重押しを防ぎたいときに使います。

ワーカーは、Saga のコンテキストと、パターンが取り出した値を受け取るクロージャ（または同じ形の関数）で書きます。

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

どれも、呼び出した時点で Action の受け取りを始め、待たずに続きを実行します。処理中に届いた Action を取りこぼすこともありません。戻り値の `SagaTask` を使えば、後から止められます。ワーカーを別の関数として定義し、名前で渡す書き方は README の Saga の節で説明しています。

ワーカーの中で処理しなかったエラーは、ヘルパーごと終了させ、呼び出し元に伝わります。エラーが起きても受け付けを続けたい場合は、ワーカーの中で `catch` してください。

redux-saga の `yield takeEvery(SAVE, saveUser)` などに当たり、3 つの意味も redux-saga と同じです。

```js
yield takeEvery(SAVE, saveUser)
yield takeLatest(SEARCH, searchUsers)
yield takeLeading(LOGIN, login)
```

## debounce と throttle: 頻繁な Action をまとめる

文字入力やスクロールのように、短い間隔で何度も届く Action を、そのたびに処理すると無駄が多くなります。`debounce` と `throttle` は、そうした Action をまとめて扱います。

`debounce` は、Action が指定した時間だけ届かなくなるのを待ってから、最後の Action で 1 回だけ処理します。文字入力が止まってから検索する、といったときに使います。`throttle` は、処理した後の一定の時間に届いた Action のうち最後の 1 つだけを残し、時間が過ぎてから処理します。スクロールに合わせた読み込みを間引く、といったときに使います。

```swift
ctx.debounce(.milliseconds(300), search) { ctx, query in
  await ctx.put(.results(try await ctx.call(api.search, query)))
}
ctx.throttle(.milliseconds(500), scrolled) { ctx, offset in
  // スクロールに合わせて続きを読み込む
}
```

`debounce` で起動した処理は、後から届いた Action によってキャンセルされることはありません。どちらも `TestClock` で時間を進めてテストできます。

redux-saga の `yield debounce(300, SEARCH, searchUsers)` と `yield throttle(500, SCROLLED, loadMore)` に当たります。ミリ秒の数値の代わりに `.milliseconds(300)` のように書きます。

```js
yield debounce(300, SEARCH, searchUsers)
yield throttle(500, SCROLLED, loadMore)
```

## all と race: 複数の処理を並行に実行する

`all` は、複数の処理を同時に始め、すべてが終わるのを待って、すべての結果を受け取ります。プロフィールと投稿を同時に読み込む、といったときに使います。いずれかが失敗すると、残りの処理を止めてそのエラーを投げます。いずれかがキャンセルで終わった場合も、残りを止めて `CancellationError` を投げます。

`race` も複数の処理を同時に始めますが、受け取るのは最初に終わった処理の結果だけで、残りは止めます。通信にタイムアウトを付けたり、ログアウトされたら読み込みを中断したりするときに使います。最初に終わった処理が失敗した場合は、そのエラーを投げます。

```swift
// all: すべての結果を受け取る
let (user, results) = try await ctx.all(
  { ctx in try await ctx.call(api.fetch, id) },
  { ctx in try await ctx.call(api.search, query) }
)

// race: 最初に終わった処理だけが値を持ち、残りは nil になる
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

並べた処理は、それぞれ子として起動され、自分の `ctx` を受け取ります。そのため、処理の中で `take` を使うこともできます。たとえば `{ ctx in try await ctx.take(.action(.logout)) }` を `race` に並べておけば、「ログアウトされたら中断する」を書けます。処理の数と結果の型は、タプルとして型検査されます。

redux-saga では、`all` に配列を、`race` にオブジェクトを渡していました。swift-redux-saga では、どちらも処理を引数に並べ、並べた順のタプルで結果を受け取ります。`race` の結果は、勝った処理の位置だけが値を持ちます。

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

## actionChannel: Action を溜めて順に処理する

`actionChannel` は、指定した Action を溜めておき、届いた順に 1 件ずつ取り出せるようにします。保存の処理を 1 件ずつ順に行いたい（同時に保存すると順序が崩れる）ときなどに使います。`take` と違い、処理中に届いた Action も溜まるので、取りこぼしがありません。

作ったチャネルは、`for try await` で読みます。

```swift
let saves = ctx.actionChannel(save)
for try await user in saves {
  try await ctx.call(api.save, user)   // 1 件ずつ順に処理する
  await ctx.put(.saved)
}
```

溜め方は `buffer:` で選べます。既定の `.unbounded` はすべて溜め、`.newest(n)` は新しい n 件だけを、`.oldest(n)` は古い n 件だけを残します。チャネルは、作った Saga が終わると自動で閉じ、Action の受け取りをやめます。`close()` を呼んで先に閉じることもできます。複数の Saga から同じチャネルを読むと、値は待ち始めた順に 1 つずつ渡されるので、同じ処理を複数で分担できます。

redux-saga の `yield actionChannel(SAVE)` と、`while (true) { yield take(channel) }` の組み合わせに当たります。redux-saga ではチャネルを明示的に閉じる必要がありましたが、swift-redux-saga では作った Saga の終わりで自動的に閉じます。

```js
const channel = yield actionChannel(SAVE)
while (true) {
  const action = yield take(channel)
  yield call(saveUser, action)
}
```

## eventChannel: 外部のイベントを受け取る

`eventChannel` は、タイマーや通知、WebSocket のような、Action ではない外部のイベントを、Saga の中で 1 件ずつ受け取れるようにします。作り方は 2 通りあります。1 つは、値を入れる `emit` を受け取って購読し、購読を解除する関数を返す関数から作る方法です。もう 1 つは、`AsyncStream` などの `AsyncSequence` から作る方法です。

```swift
// 購読する関数から作る
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

// AsyncSequence から作る
let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
for try await message in ctx.eventChannel(from: stream) {
  // WebSocket などのメッセージを 1 件ずつ処理する
}
```

購読を解除する関数は、チャネルが閉じられたとき、つまり作った Saga が終わったときに呼ばれます。イベント源が障害で終わった場合は、`finish(throwing: error)` を呼びます。すると受け取り側の `for try await` は、溜まっている値を受け取り終えた後にそのエラーを投げます。正常な終わり（`finish()`）と区別できるので、再接続などの処理を書けます。`eventChannel(from:)` では、シーケンスが投げたエラーがそのまま伝わります。

redux-saga の `eventChannel(emit => { ...; return unsubscribe })` に当たり、形はほぼ同じです。違いは、`emit` に加えて終わりを伝える `finish` を受け取ることと、`yield take(channel)` のループの代わりに `for try await` で読むことです。

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
