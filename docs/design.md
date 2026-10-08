# 設計書

swift-redux-saga の設計方針です。公開 API を変更する PR は、この文書も同じ PR で更新します。

シグネチャは「案」であり、実装時に細部（引数ラベル、ジェネリクスの制約など）は変わり得ます。変える場合はこの文書を更新します。

## 目次

1. [ゴールと非ゴール](#1-ゴールと非ゴール)
2. [動作環境](#2-動作環境)
3. [ターゲット構成](#3-ターゲット構成)
4. [並行性と隔離の方針](#4-並行性と隔離の方針)
5. [Redux 本体](#5-redux-本体)
6. [Saga](#6-saga)
7. [Redux と Saga の接続](#7-redux-と-saga-の接続)
8. [エラー処理](#8-エラー処理)
9. [テスト支援](#9-テスト支援)
10. [SwiftUI / UIKit 連携](#10-swiftui--uikit-連携)
11. [ロックイン回避](#11-ロックイン回避)
12. [マクロ（任意）](#12-マクロ任意)
13. [旧実装（ReSwift-Saga）からの変更点](#13-旧実装reswift-sagaからの変更点)
14. [未決事項](#14-未決事項)

---

## 1. ゴールと非ゴール

### ゴール

- Swift 6 言語モード（strict concurrency）で警告ゼロ。
- 外部ライブラリに依存しない（マクロターゲットの swift-syntax のみ例外）。
- 主目的は Saga。Redux 本体は Saga の土台だが、単体でも使える品質にする。
- ビジネスロジック（UseCase / Repository）が本ライブラリを import せずに書ける。
- Saga のキャンセルは親から子へ必ず伝播する（構造化並行性）。

### 非ゴール

- redux-saga の Effect を 1 ステップずつ検証するテスト（ジェネレーターが前提のため）。代わりに「結果を検証する」テストを支援する（[9 章](#9-テスト支援)）。
- Combine 対応（必要になれば別ターゲットのアダプタとして検討）。
- Redux DevTools 連携、RTK Query 相当の機能。

---

## 2. 動作環境

| 項目 | 方針（案） |
| --- | --- |
| Swift ツールチェーン | **Swift 6.2 以降（Xcode 26 以降）**。`swift-tools-version: 6.2` |
| 言語モード | Swift 6（`swiftLanguageModes: [.v6]`） |
| iOS | 17 以降 |
| macOS | 14 以降 |
| tvOS | 17 以降 |
| watchOS | 10 以降 |
| visionOS | 1 以降 |
| Linux | UI に依存しないターゲット（`Redux` / `Saga` / `ReduxSaga` / `SagaTesting`）をビルド・テスト対象にする |

OS の下限は Observation（iOS 17 / macOS 14 など）で決まります。

ツールチェーンを 6.2 以上にする理由:

- `.defaultIsolation(MainActor.self)` を使ったテストターゲットを Package.swift に置き、「アプリが default MainActor isolation を有効にしていても使えること」を CI で保証したい（PackageDescription 6.2 から）。
- `Observations`（Swift 6.2 の標準ライブラリ。OS 側は iOS 26 / macOS 26 などで利用可能）を `#if compiler` なしで参照したい。
- App Store への提出は Xcode 26 以降が前提になっているため、利用者側の制約は小さい。

Swift 6.0 / 6.1 を残すかどうかは[要確認事項](#14-未決事項)です。

### Observation 関連 API の OS 対応（Apple 公式ドキュメントで確認済み）

| API | 対応 OS |
| --- | --- |
| `@Observable` / `withObservationTracking` | iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 |
| UIKit の Observation 自動追跡（`Info.plist` の `UIObservationTrackingEnabled` でオプトイン） | iOS 18 / iPadOS 18 |
| UIKit の Observation 自動追跡（既定で有効）、`UIView.updateProperties()` / `UIViewController.updateProperties()` | iOS 26 / tvOS 26 / visionOS 26 / Mac Catalyst 26 |
| `Observations`（AsyncSequence） | iOS 26 / macOS 26 / tvOS 26 / watchOS 26 / visionOS 26 |

参照:

- https://developer.apple.com/documentation/observation/observations
- https://developer.apple.com/documentation/bundleresources/information-property-list/uiobservationtrackingenabled
- https://developer.apple.com/documentation/uikit/uiview/updateproperties()

---

## 3. ターゲット構成

```
swift-redux-saga
├── Redux            Store / Reducer / Middleware / Slice / Selector / EntityAdapter / 購読 API
├── Saga             Saga ランタイムと Effect。Redux に依存しない
├── ReduxSaga        Redux の Middleware として Saga を載せるアダプタ（Redux + Saga）
├── ReduxSwiftUI     SwiftUI 用ヘルパー（Redux）
├── ReduxUIKit       UIKit 用ヘルパー（Redux）
├── SagaTesting      TestClock、SagaTester、Action の記録（Saga）
├── ReduxTesting     TestStore（Redux）
└── ReduxMacros      マクロ（任意・最後に追加。swift-syntax に依存）
```

依存関係:

```
Redux ◀── ReduxSaga ──▶ Saga
  ▲                       ▲
  ├── ReduxSwiftUI        └── SagaTesting
  ├── ReduxUIKit
  └── ReduxTesting
```

- `Saga` は `Redux` に依存しない。Store とは [`SagaHost`](#62-sagahost-プロトコル) という小さなプロトコル越しにつながる。
- `ReduxSwiftUI` / `ReduxUIKit` は `#if canImport(SwiftUI)` / `#if canImport(UIKit)` で囲み、Linux でもパッケージ全体の `swift build` が通るようにする。
- テスト支援は本体と分ける（アプリ本体に XCTest / Testing 依存を持ち込まないため）。テスト支援ターゲットは Swift Testing を import しない（アサーションの失敗は呼び出し側に `throws` で返す）。
- Example は `Examples/` 配下に別パッケージ + Xcode プロジェクトとして置き、ライブラリ本体の依存グラフに含めない。

### プロダクト

| プロダクト | ターゲット |
| --- | --- |
| `Redux` | `Redux` |
| `Saga` | `Saga` |
| `ReduxSaga` | `Redux`, `Saga`, `ReduxSaga` |
| `ReduxSwiftUI` | `ReduxSwiftUI` |
| `ReduxUIKit` | `ReduxUIKit` |
| `SagaTesting` | `SagaTesting` |
| `ReduxTesting` | `ReduxTesting` |

---

## 4. 並行性と隔離の方針

| 対象 | 隔離 |
| --- | --- |
| `Store` | `@MainActor` |
| Reducer | 同期の純粋関数。`@Sendable (inout State, Action) -> Void`。Store から `@MainActor` 上で呼ばれる |
| Middleware | `@MainActor` 上で同期に呼ばれる |
| Saga | メインアクター外（`nonisolated` な async 関数）で実行。Store へのアクセスは `await` を伴う |
| `Action` / `State` | `Sendable` 必須 |
| チャネル | Store / `SagaRuntime` のインスタンスが所有。グローバルな可変状態は持たない |

### 原則

- グローバルな可変状態（`static var`、シングルトン）を持たない。
- `@unchecked Sendable` と `nonisolated(unsafe)` は原則使わない。使う場合は理由と、安全性の根拠をコメントに書く。
- 排他制御は内部型 `Locked<Value>` に集約する。Darwin では `OSAllocatedUnfairLock`、Linux では `Synchronization.Mutex` を使う（`Mutex` は Apple OS では iOS 18 / macOS 15 からのため）。
- 非同期のブリッジ（continuation）は必ずキャンセルハンドラを持ち、キャンセル時に登録を解除して resume する。リークを防ぐため、全 continuation が「ちょうど 1 回 resume される」ことをテストで確認する。

### default MainActor isolation を有効にしたアプリでの利用

ライブラリ自体は default isolation を使わず、公開 API の隔離をすべて明示します（`@MainActor` / `nonisolated` / `@Sendable`）。これにより、利用側の設定に関係なく同じ意味になります。

利用側への注意（README とドキュメントコメントに記載）:

- default MainActor isolation のモジュールで定義した型は暗黙に `@MainActor` になり、`Equatable` などの準拠も MainActor 隔離になる（SE-0470）。Saga はメインアクター外で動くため、**Action / State は `nonisolated` を付けて宣言する**ことを推奨する。
- 推奨構成（[11 章](#11-ロックイン回避)）では、Action / Reducer / Saga を置く `AppFeature` ターゲットは default isolation を使わない。

CI では、`.defaultIsolation(MainActor.self)` を設定したテストターゲットと、設定しないテストターゲットの両方で同じ利用コードをコンパイル・実行します。

---

## 5. Redux 本体

### 5.1 Action と State

Action と State に専用のプロトコルは設けず、`Sendable` であることだけを要求します。

```swift
nonisolated enum AppAction: Sendable {
  case counter(CounterAction)
  case todos(TodosAction)
}

nonisolated struct AppState: Sendable, Equatable {
  var counter = CounterState()
  var todos = TodosState()
}
```

`Store<State, Action>` の `Action` には、enum のほか、プロトコル存在型（`any AppActionProtocol`）も使えます。RTK のように「Action ごとに型を分ける」スタイルを取りたい場合は後者を使い、[型による判定](#64-action-のマッチング)を利用します。

### 5.2 Reducer

```swift
public struct Reducer<State: Sendable, Action: Sendable>: Sendable {
  public init(_ reduce: @escaping @Sendable (inout State, Action) -> Void)
  public func reduce(into state: inout State, action: Action)
}
```

合成:

```swift
extension Reducer {
  /// 複数の reducer を順に適用する。
  public static func combine(_ reducers: Reducer...) -> Reducer

  /// 子の reducer を親の State / Action に持ち上げる。
  /// `action` が nil を返した Action は子に渡さない。
  public static func scope<ChildState, ChildAction>(
    state: WritableKeyPath<State, ChildState> & Sendable,
    action: @escaping @Sendable (Action) -> ChildAction?,
    reducer: Reducer<ChildState, ChildAction>
  ) -> Reducer
}

/// `Reducer.combine` を宣言的に書くための result builder。
@resultBuilder
public enum ReducerBuilder<State: Sendable, Action: Sendable> { ... }
```

Immer 相当の「直接書き換え」は `inout` で実現します。

### 5.3 Store

```swift
@MainActor
@Observable
@dynamicMemberLookup
public final class Store<State: Sendable, Action: Sendable> {
  public init(
    initialState: State,
    reducer: Reducer<State, Action>,
    middleware: [any Middleware<State, Action>] = []
  )

  /// 現在の State 全体。参照すると State 全体の変化が追跡対象になる。
  public var state: State { get }

  /// State の一部を参照する。参照したキーパスだけが追跡対象になる（5.4 を参照）。
  public subscript<Value: Equatable>(dynamicMember keyPath: KeyPath<State, Value> & Sendable) -> Value { get }
  /// 値が Equatable でない場合。State 全体の変化が追跡対象になる。
  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value> & Sendable) -> Value { get }

  /// Action を同期で処理する。ミドルウェア → reducer の順に適用される。
  public func dispatch(_ action: Action)
}
```

`configureStore` 相当として、result builder でまとめて書ける初期化子も用意します。

```swift
let store = Store(initialState: AppState()) {
  Reducer.scope(state: \.counter, action: \.counter, reducer: Counter.reducer)
  Reducer.scope(state: \.todos, action: \.todos, reducer: Todos.reducer)
} middleware: {
  sagaMiddleware
  LoggerMiddleware()
}
```

（`action: \.counter` のような書き方は enum の case キーパスがない Swift では使えないため、マクロなしでは `action: { if case .counter(let a) = $0 { a } else { nil } }` と書きます。マクロ版で短くします。）

dispatch の処理中に `dispatch` が呼ばれた場合（ミドルウェアや Observation の通知の中から呼ばれた場合）は、その場では処理せずキューに積み、処理中の Action が終わった後に呼ばれた順に処理します。

- 再入をその場で処理しないのは、通知の途中で State が書き換わり、先に呼ばれた Action より後の Action の結果が先に見えてしまうため。
- 再入を禁止（`assertionFailure`）しないのは、SwiftUI / UIKit の Observation の通知からの dispatch は利用側で避けにくく、禁止すると実用上困るため。
- reducer は Store を参照できない `@Sendable` の純粋関数なので、reducer の中からの dispatch は型の上で起こらない。

### 5.4 Observation の追跡単位（プロパティ単位の再描画）

`@Observable` のマクロで `state` プロパティを追跡するだけだと、`store.state.count` を読んだ View は State のどのプロパティが変わっても再描画されます。プロパティ単位の追跡のために、Store は `ObservationRegistrar` を自前で管理します。

- `store.count`（dynamic member）を読むと、`\Store.state` にキーパス `\State.count` をつないだキーパスをアクセスとして登録する。
- 登録時に、そのキーパスの新旧の値を比較するクロージャ（`Value: Equatable` を使う）を Store 内の表に記録する。
- `dispatch` で reducer を適用した後、表にあるキーパスについて新旧の値を比較し、変わったものだけ `willSet` / `didSet` を通知する。変わったキーパスがすべて `willSet` → 代入 → すべて `didSet` の順にする。
- `store.state` を直接読んだ場合は `\Store.state` 全体の変更として通知する。State が `Equatable` なら、変化がないときは通知しない。
- 値が `Equatable` でないプロパティを dynamic member で読んだ場合は、`\Store.state` 全体の変更として扱う。
- 追跡の単位は Store から直接読んだプロパティ。`store.profile.name` は `profile` の変化で通知される（`name` 以外が変わっても通知される）。

比較のコストは「これまでに参照されたキーパスの種類数」に比例します。表の要素はコード中で使われるキーパスの種類数で頭打ちになるため、削除しません。

### 5.5 Middleware

```swift
@MainActor
public protocol Middleware<State, Action> {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Store の生成時に 1 回呼ばれる（既定の実装は何もしない）。
  func attach(to store: MiddlewareAPI<State, Action>)

  /// Action ごとに呼ばれる。`next` を呼ぶと次のミドルウェア（最後は reducer）に進む。
  func handle(_ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void)
}

/// ミドルウェアに渡す Store の窓口。Store を弱参照で持つ。
@MainActor
public struct MiddlewareAPI<State: Sendable, Action: Sendable> {
  public var isStoreAlive: Bool { get }
  /// Observation の追跡対象にならない。Store の解放後に読むと停止する。
  public var state: State { get }
  /// handle の中から呼んだ場合は、処理中の Action の後に処理される。Store の解放後は何もしない。
  public func dispatch(_ action: Action)
}
```

- プロトコル全体を `@MainActor` にするのは、Store と同じ隔離で同期に呼ぶため。
- `next` をエスケープしないクロージャにしているのは、reducer への到達を `handle` の中に限定し、非同期に `next` を呼べないようにするため。非同期の処理は `MiddlewareAPI.dispatch` で新しい Action として流す。

Saga を載せるミドルウェアはこの仕組みの上に `ReduxSaga` ターゲットで実装します（[7 章](#7-redux-と-saga-の接続)）。

### 5.6 Slice（`createSlice` 相当）

Swift では enum の case が「Action 作成関数」の役割を果たすため、Slice は State・Action・reducer を 1 つの名前空間にまとめるプロトコルとして定義します。

```swift
public protocol Slice {
  associatedtype State: Sendable
  associatedtype Action: Sendable
  static var initialState: State { get }
  static func reduce(into state: inout State, action: Action)
}

extension Slice {
  public static var reducer: Reducer<State, Action> { get }
}
```

```swift
enum Counter: Slice {
  struct State: Sendable, Equatable { var count = 0 }
  enum Action: Sendable { case increment, decrement, add(Int) }
  static let initialState = State()
  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .increment: state.count += 1
    case .decrement: state.count -= 1
    case .add(let n): state.count += n
    }
  }
}
```

### 5.7 Selector（`createSelector` 相当）

入力セレクタの結果が前回と同じ（`Equatable`）なら、前回の出力を返します。パラメータパックで入力セレクタの数を任意にします。

```swift
public struct Selector<State: Sendable, Output: Sendable>: Sendable {
  public func callAsFunction(_ state: State) -> Output
}

public func createSelector<State: Sendable, each Input: Equatable & Sendable, Output: Sendable>(
  _ inputs: repeat @escaping @Sendable (State) -> each Input,
  result: @escaping @Sendable (repeat each Input) -> Output
) -> Selector<State, Output>
```

キャッシュは Saga（メインアクター外）からも使われるため、`Locked` で保護します。キャッシュサイズは 1（RTK の既定と同じ）。

### 5.8 Entity Adapter（`createEntityAdapter` 相当）

```swift
public struct EntityState<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  public var ids: [ID]
  public var entities: [ID: Entity]
}

public struct EntityAdapter<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  public init(id: KeyPath<Entity, ID> & Sendable, sort: (@Sendable (Entity, Entity) -> Bool)? = nil)

  public func addOne(_ entity: Entity, to state: inout EntityState<ID, Entity>)
  public func addMany(_ entities: some Sequence<Entity>, to state: inout EntityState<ID, Entity>)
  public func setOne / setMany / setAll
  public func upsertOne / upsertMany
  public func updateOne(id: ID, in state: inout EntityState<ID, Entity>, _ update: (inout Entity) -> Void)
  public func removeOne / removeMany / removeAll

  public func selectAll(_ state: EntityState<ID, Entity>) -> [Entity]
  public func selectByID(_ id: ID, in state: EntityState<ID, Entity>) -> Entity?
}

extension EntityAdapter where Entity: Identifiable, ID == Entity.ID {
  public init(sort: ...)
}
```

### 5.9 OS に依存しない購読 API

UIKit やテスト、SwiftUI 以外から State の変化を受け取るための API です。iOS 17 以降で動きます（`withObservationTracking` を使う）。

```swift
extension Store {
  /// `read` の中で読んだ値を、すぐに 1 回、その後は変わるたびに `onChange` に渡す。
  /// トークンを cancel するか解放すると購読を解除する。
  public func observe<Value>(
    _ read: @escaping @MainActor (Store) -> Value,
    onChange: @escaping @MainActor (Value) -> Void
  ) -> ObservationToken

  /// 値の変化を AsyncStream として受け取る（最新の値だけをバッファする）。
  public func values<Value: Sendable>(
    _ read: @escaping @MainActor (Store) -> Value
  ) -> AsyncStream<Value>
}

@MainActor public final class ObservationToken {
  public func cancel()
}
```

- 変化の通知は、変更が終わった後にメインアクター上で非同期に届く。`withObservationTracking` の onChange は変更の直前に呼ばれ、新しい値を読めないため。続けて変更された場合は最後の値だけが届くことがある。
- iOS 26 以降でも `Observations` を使わず、同じ実装を使う。OS によって通知のタイミングが変わらないようにするため。iOS 26 以降のアプリは `Observations { store.count }` を直接使ってもよい（Store は `Observable` なので、そのまま動く）。
- 購読は Store とトークンを弱参照で持ち、Store や呼び出し元を延命しない。

---

## 6. Saga

### 6.1 全体像

```
                ┌──────────────── SagaRuntime ────────────────┐
 Store ──emit──▶│ ActionMulticaster ──▶ takers / channels     │
 (Host)         │                                              │
       ◀─put────│ root Saga ─fork─▶ child ─fork─▶ grandchild   │
       ─state──▶│        (TaskGroup の子タスク = 構造化並行性)   │
                └──────────────────────────────────────────────┘
```

- `SagaRuntime` は 1 つの Store（Host）に対して 1 つ。Action の配信用チャネルはランタイムのインスタンスが所有する。
- Saga は「Action を受け → ビジネスロジックを呼び → 結果を Action で返す」薄い層として書く。

### 6.2 SagaHost プロトコル

Saga のコアは Redux の具体型に依存せず、次のプロトコル越しに動きます。

```swift
public protocol SagaHost<State, Action>: Sendable {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Action を発行する。reducer の適用が終わってから戻る。
  func dispatch(_ action: Action) async

  /// 現在の State を返す。
  func state() async -> State
}
```

Action の流れ込み（Host → Saga）は、Host 側が `SagaRuntime.emit(_:)` を呼ぶことで行います。これにより、ReSwift 用や他の状態管理用のアダプタも、このプロトコルを実装して `emit` を呼ぶだけで作れます。

### 6.3 Saga と SagaContext

Saga は「コンテキストを受け取る async 関数」です。旧実装のように Action を引数に取りません。

```swift
public struct Saga<State: Sendable, Action: Sendable>: Sendable {
  public init(_ body: @escaping @Sendable (SagaContext<State, Action>) async throws -> Void)

  /// 現在のコンテキストで本体を実行する（ほかの Saga の中から呼び出す場合）。
  public func run(_ context: SagaContext<State, Action>) async throws

  /// 複数の Saga を並行に実行する（内部で `all`）。
  public static func combine(_ sagas: Saga...) -> Saga
}

/// Effect を提供する。Sendable な値型で、内部でランタイムと現在のスコープを参照する。
public struct SagaContext<State: Sendable, Action: Sendable>: Sendable { ... }
```

#### ジェネレーター関数（`function*`）との対応

redux-saga ではジェネレーター関数の中で `yield` を使って Effect を返し、ミドルウェアがそれを実行します。Swift にはジェネレーターがないため、**Saga は `async` 関数として書き、Effect は `SagaContext` のメソッドを `await` で直接呼びます**。`yield` が `await` に置き換わるイメージです。

```js
// redux-saga
function* fetchUser(action) {
  try {
    const user = yield call(api.fetchUser, action.payload.id)
    yield put({ type: 'user/fetched', payload: user })
  } catch (e) {
    yield put({ type: 'user/failed', payload: e.message })
  }
}

function* rootSaga() {
  yield takeLatest('user/fetch', fetchUser)
}
```

```swift
// swift-redux-saga
func fetchUser(_ ctx: AppSagaContext, id: User.ID) async throws {
  do {
    let user = try await ctx.call(fetchUserUseCase.execute, id)
    await ctx.put(.user(.fetched(user)))
  } catch {
    await ctx.put(.user(.failed(error.localizedDescription)))
  }
}
```

| redux-saga | swift-redux-saga |
| --- | --- |
| `function* saga() { ... }` | `func saga(_ ctx: SagaContext<State, Action>) async throws { ... }` |
| `yield take(...)` / `yield put(...)` | `try await ctx.take(...)` / `await ctx.put(...)` |
| `yield call(fn, a, b)` | `try await ctx.call(fn, a, b)`（`try await fn(a, b)` と直接書いてもよい） |
| `const v = yield select(selector)` | `let v = await ctx.select(selector)` |
| `try { } finally { if (yield cancelled()) { } }` | `do { } catch is CancellationError { }` / `ctx.isCancelled` |
| ワーカーの引数 `action` | パターンで取り出した値（`id` など）。Action 全体を受け取らない |

#### Effect をトップレベル関数にしない

旧実装では `take` / `put` / `call` などをトップレベル関数として提供していました。新実装では Effect は **`SagaContext` のメソッド**にします。

トップレベル関数を採らない理由:

- `take` / `call` / `select` / `all` / `race` / `delay` / `cancel` は一般的な名前で、利用側やほかのモジュールの関数と衝突しやすい。
- どのランタイム（どの Store）に対する Effect かを関数が知る手段がなく、旧実装ではグローバルな `Bridge.shared` が必要になった。タスクローカル値で渡す方法もあるが、Saga の外で呼んだときにコンパイルエラーにできない。
- `State` / `Action` の型を呼び出しごとに推論させる必要があり、型推論が重く、エラーメッセージも分かりにくい。
- `ctx.` と打てば使える Effect が補完で一覧できる。

`enum` で名前空間を区切る案（`Effects.take(...)`）も、2 つ目と 3 つ目の問題が残るため採りません。

#### Saga の定義のまとめ方

Saga 自体もトップレベル関数にせず、機能ごとに型にまとめます。依存（UseCase など）があるときは、それをプロパティに持つ `struct` にします。初期化時に依存を注入でき、シングルトンを使わずに済みます。

```swift
typealias AppSagaContext = SagaContext<AppState, AppAction>

struct UserSagas: Sendable {
  let fetchUserUseCase: FetchUserUseCase   // Domain の型。本ライブラリに依存しない

  /// この機能のルート Saga。
  var root: Saga<AppState, AppAction> {
    Saga { ctx in
      ctx.takeLatest(.case { if case .user(.fetch(let id)) = $0 { id } else { nil } }) { ctx, id in
        try await fetchUser(ctx, id: id)
      }
    }
  }

  func fetchUser(_ ctx: AppSagaContext, id: User.ID) async throws {
    do {
      let user = try await ctx.call(fetchUserUseCase.execute, id)
      await ctx.put(.user(.fetched(user)))
    } catch {
      await ctx.put(.user(.failed(error.localizedDescription)))
    }
  }
}

// アプリ本体（組み立て）
let userSagas = UserSagas(fetchUserUseCase: LiveFetchUserUseCase(api: apiClient))
sagaMiddleware.run(Saga { ctx in
  try await ctx.all(
    { try await userSagas.root.run(ctx) },
    { try await todoSagas.root.run(ctx) }
  )
})
```

依存のない Saga は、`case` のない `enum` を名前空間にして `static` メンバーとして定義してもかまいません。

```swift
enum CounterSagas {
  static var root: Saga<AppState, AppAction> { ... }
}
```

`Saga` 型には、複数の Saga をまとめる `Saga.combine(_:)`（内部で `all` を使う）も用意し、上の組み立てを `Saga.combine(userSagas.root, todoSagas.root)` と書けるようにします。

### 6.4 Action のマッチング

```swift
public struct ActionPattern<Action: Sendable, Value: Sendable>: Sendable {
  public init(_ extract: @escaping @Sendable (Action) -> Value?)

  /// enum の case などから値を型付きで取り出す。
  public static func `case`(_ extract: @escaping @Sendable (Action) -> Value?) -> Self
}

extension ActionPattern where Value == Action {
  /// すべての Action。
  public static var any: Self { get }
  /// 条件に合う Action。
  public static func filter(_ predicate: @escaping @Sendable (Action) -> Bool) -> Self
}

extension ActionPattern {
  /// 型による判定（`Action` がプロトコル存在型のとき用）。`as?` でキャストする。
  public static func type(_ type: Value.Type) -> Self
}
```

`SagaContext` の各 Effect は `ActionPattern` を受け取り、取り出した `Value` を返します。enum の case から値を取り出すクロージャはマクロ版で生成できるようにします（[12 章](#12-マクロ任意)）。

### 6.5 Effect 一覧

| redux-saga | Swift API（案） | 補足 |
| --- | --- | --- |
| `take` | `func take<V>(_ p: ActionPattern<Action, V>) async throws -> V` | 次に来た一致する Action を待つ |
| `put` | `func put(_ action: Action) async` | reducer 適用後に戻る |
| `select` | `func select<T: Sendable>(_ s: @Sendable (State) -> T) async -> T` / `func select() async -> State` | |
| `call` | `func call<each A: Sendable, R: Sendable>(_ f: @Sendable (repeat each A) async throws -> R, _ args: repeat each A) async throws -> R` | 任意の async 関数を呼ぶ |
| `fork` | `func fork(_ body: ...) -> SagaTask` | attached。親のキャンセルが伝播し、子のエラーは親に伝播する |
| `spawn` | `func spawn(_ body: ...) -> SagaTask` | detached。ランタイム停止時のみキャンセルされる |
| `cancel` | `SagaTask.cancel()` | |
| `join` | `SagaTask.join() async throws` | |
| `cancelled` | `ctx.isCancelled` / `Task.isCancelled` | |
| `delay` | `func delay(_ duration: Duration) async throws` | ランタイムに注入した `Clock` を使う |
| `takeEvery` | `func takeEvery<V>(_ p, _ worker) -> SagaTask` | 非ブロッキング（内部で fork） |
| `takeLatest` | `func takeLatest<V>(_ p, _ worker) -> SagaTask` | 前回のワーカーをキャンセル |
| `takeLeading` | `func takeLeading<V>(_ p, _ worker) -> SagaTask` | 実行中は新しい Action を無視 |
| `debounce` | `func debounce<V>(_ d: Duration, _ p, _ worker) -> SagaTask` | |
| `throttle` | `func throttle<V>(_ d: Duration, _ p, _ worker) -> SagaTask` | |
| `all` | `func all<each R>(_ ops: repeat @Sendable () async throws -> each R) async throws -> (repeat each R)` | 1 つでも失敗したら他をキャンセル |
| `race` | `func race<each R>(_ ops: repeat @Sendable () async throws -> each R) async throws -> (repeat (each R)?)` | 最初に終わったもの以外はキャンセル。戻り値は勝者のみ非 nil |
| `actionChannel` | `func actionChannel<V>(_ p, buffer: ChannelBuffer) -> SagaChannel<V>` | |
| `eventChannel` | `func eventChannel<V>(buffer:, _ subscribe:) -> SagaChannel<V>` / `func eventChannel(from: some AsyncSequence)` | |

`call` を使わず `try await useCase.execute(id)` と直接書いても動きます。`call` を使うと、呼び出し前のキャンセル確認と、モニタ（[8 章](#8-エラー処理)）への記録が行われます。

### 6.6 fork / spawn の実装方針（構造化並行性）

- 各 Saga は「スコープ」を持つ。スコープは `withThrowingDiscardingTaskGroup` を開き、Saga 本体と fork された子をすべてそのグループの子タスクとして実行する。
- `fork` は同期関数。スコープが持つ要求キュー（`AsyncStream`）に子の起動要求を積み、グループ側のループがそれを `addTask` する。したがって子は親タスクの本物の子タスクであり、親のキャンセルは自動で伝播する。
- 親（Saga 本体）は、本体が終わってもすべての子が終わるまで完了しない（redux-saga と同じ）。
- 子が未処理のエラーで終わるとグループが失敗し、兄弟と親がキャンセルされ、エラーが親に伝播する。
- 個々の子を `SagaTask.cancel()` で止めるため、子は自分用のキャンセル信号を持ち、信号を受けたら自身の内側のタスクグループをキャンセルする。
- `spawn` はランタイムが持つルートスコープに子を追加する。呼び出し元の親とは切り離されるが、ランタイムの停止（Store の破棄など）でキャンセルされる。`Task.detached` は使わない。

### 6.7 take の配信方式

- ランタイムは `ActionMulticaster` を持ち、`emit` された Action を、その時点で登録されている taker（`take` 待ち）とチャネルに配る。
- `take` は 1 回限りの taker を登録して待つ。キャンセルされたら登録を外して `CancellationError` を投げる。購読が溜まることはない。
- `take` を繰り返すループでは、ワーカーの実行中に来た Action は受け取れない（redux-saga と同じ）。取りこぼしたくない場合は `actionChannel` か `takeEvery` を使う。
- `takeEvery` などのヘルパーは内部で永続的な購読（バッファ付き）を使い、取りこぼさない。

### 6.8 時間

`SagaRuntime` は `any Clock<Duration>` を受け取ります（既定は `ContinuousClock`）。`delay` / `debounce` / `throttle` はこの Clock を使うため、テストでは `TestClock` に差し替えて時間を進められます。

---

## 7. Redux と Saga の接続

`ReduxSaga` ターゲットが提供します。

```swift
@MainActor
public final class SagaMiddleware<State: Sendable, Action: Sendable>: Middleware {
  public init(clock: any Clock<Duration> = ContinuousClock(), monitor: (any SagaMonitor)? = nil, onError: ...)

  /// ルート Saga を起動する。Store の生成後に呼ぶ。
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask

  /// すべての Saga をキャンセルする。
  public func stop()
}
```

- `handle` では `next(action)`（reducer 適用）の後に `runtime.emit(action)` を呼ぶ。redux-saga と同じく、Saga が受け取るのは reducer 適用後の Action。
- Host（Store 側の窓口）は Store を弱参照する。Store が解放されたらランタイムを停止する。これにより Store ⇄ ミドルウェア ⇄ ランタイムの循環参照を作らない。
- `put` は `await MainActor.run { store.dispatch(action) }` 相当。

---

## 8. エラー処理

| 状況 | 振る舞い |
| --- | --- |
| fork した子で未処理のエラー | 兄弟と親をキャンセルし、親にエラーを伝播する（redux-saga と同じ） |
| ルート Saga まで伝播したエラー | ランタイムの `onError` ハンドラを呼び、その Saga ツリーを終了する |
| spawn した Saga の未処理のエラー | 呼び出し元には伝播しない。`onError` ハンドラを呼ぶ |
| `CancellationError` | エラーとして報告しない |
| `takeEvery` などのワーカー内のエラー | ワーカーの fork 元（ヘルパー）に伝播し、ヘルパーごと終了する（redux-saga と同じ）。継続したい場合はワーカー内で `catch` する |

```swift
public struct SagaError: Error {
  public var underlying: any Error
  /// エラーが伝播した Saga の経路（デバッグ用の名前。`Saga(name:)` で指定）。
  public var sagaStack: [String]
}

public protocol SagaMonitor: Sendable {
  func sagaStarted(id: SagaID, name: String?, parent: SagaID?)
  func sagaFinished(id: SagaID, result: SagaResult)
  func effectTriggered(id: SagaID, effect: EffectDescription)
}
```

- 既定の `onError` は、Darwin では `os.Logger`、Linux では標準エラー出力にログを出す。
- `SagaMonitor` はログ出力やデバッグツール用のフック。テスト支援もこれを使う。

---

## 9. テスト支援

Swift にはジェネレーターがないため、redux-saga の「Effect を 1 ステップずつ取り出して検証する」テストは再現しません。代わりに、Saga を実際に動かして**結果（発行された Action と State）を検証する**テストを書きやすくします。この違いは README に明記します。

```swift
@Test func fetchUser() async throws {
  let clock = TestClock()
  let tester = SagaTester(
    initialState: AppState(),
    reducer: appReducer,
    saga: UserSagas(fetchUserUseCase: StubFetchUserUseCase(User(id: 1))).root,
    clock: clock
  )

  await tester.send(.user(.fetch(1)))
  try await tester.receive(.user(.fetched(User(id: 1))))   // Action が Equatable の場合
  #expect(tester.state.user == User(id: 1))
  try await tester.finish()   // 残っている Saga がないこと、未確認の Action がないこと
}
```

| 型 | ターゲット | 役割 |
| --- | --- | --- |
| `TestClock` | `SagaTesting` | 手動で進める `Clock`。`advance(by:)` / `run()` |
| `SagaTester` | `SagaTesting` | Store なしで Saga を動かす。発行された Action を記録し、State を reducer で更新する |
| `TestStore` | `ReduxTesting` | 本物の `Store` + ミドルウェアを使い、Action と State の変化を記録・検証する |

### フレーキーにしないための仕組み

時間や `Task.yield()` の回数に頼らないため、ランタイムは「すべての Saga が Effect（`take` / `delay` / チャネル待ち）で止まっているか」を数えます。テスト支援の `settle()` はこの状態になるまで待ちます。`receive` / `advance(by:)` は内部で `settle()` を呼びます。

---

## 10. SwiftUI / UIKit 連携

### SwiftUI（`ReduxSwiftUI`）

- `Store` は `@Observable` なので、`@State` / `@Environment` でそのまま扱える。
- ヘルパー:
  - `View.store(_:)`: `Environment` に Store を入れる。
  - `@Environment(Store<AppState, AppAction>.self)` で取り出す。
  - `store.binding(\.text, send: AppAction.setText)`: State の値と Action から `Binding` を作る。

### UIKit（`ReduxUIKit`）

- iOS 26 以降（および `UIObservationTrackingEnabled` を有効にした iOS 18 以降）は、`viewWillLayoutSubviews()` / `layoutSubviews()` / `updateProperties()` などで `store.count` を読むだけで UIKit が自動で追跡する。ライブラリ側の追加作業はない（5.4 の追跡単位がそのまま効く）。
- それ以前の OS や、ライフサイクル外で購読したい場合は `store.observe(_:onChange:)`（5.9）を使う。
- ヘルパー: `ObservationToken` を `UIViewController` の寿命に結びつけるユーティリティなど、最小限にする。

---

## 11. ロックイン回避

### 原則

1. ビジネスロジック（UseCase / Repository / Model）は本ライブラリを import しない。
2. Saga は「Action → ビジネスロジック呼び出し → Action」の接着層に限定する。
3. `call` は任意の async 関数を受け取る。Action を引数に取る関数に限定しない。
4. 依存は Saga を作る関数の引数で注入する。
5. Saga のコアは `SagaHost` プロトコル越しに動き、Redux 本体の具体型に依存しない。

### 推奨ターゲット構成（Example で示す）

```
Domain       本ライブラリに依存しない（UseCase / Repository / Model）
AppFeature   Domain + 本ライブラリ（Action / State / Reducer / Saga）
App          View と Store の組み立て（依存の注入）
```

---

## 12. マクロ（任意）

マクロは最後に、別ターゲット `ReduxMacros` として追加します。マクロなしで全機能が使える API を先に完成させます。

候補:

- `@CasePathable` 相当（名前は実装時に決定）: enum の各 case について `ActionPattern` と抽出クロージャを生成する（`.case(\.user.fetch)` に近い書き方を可能にする）。
- `@Slice`: Slice の定型コードを生成する。

---

## 13. 旧実装（ReSwift-Saga）からの変更点

| 旧実装の問題 | 新実装 |
| --- | --- |
| `Bridge.shared` というグローバルな可変シングルトンで Action を配信 | チャネルは `SagaRuntime` のインスタンスが所有する。グローバルな可変状態なし |
| `fork` が `Task.detached` で、親のキャンセルが子に伝播しない | `fork` は TaskGroup の子タスク（attached）。`spawn` だけが親から切り離される |
| `take` が Combine の `Future` + `sink` で購読し、購読が解除されずに溜まる | `take` は 1 回限りの taker を登録し、完了・キャンセル時に必ず解除する。Combine は使わない |
| Action の判定が `type(of:) ==` のみで、enum の Action を扱えない | `ActionPattern`（型による判定と `(Action) -> Value?` のパターンマッチ） |
| Saga の型が `(Action) async throws -> T` で、ビジネスロジックが Action 型に依存 | Saga は `SagaContext` を受け取る。`call` は任意の async 関数を受け取り、依存は引数で注入する |
| ReSwift に依存 | Redux 本体も自作し、Saga は `SagaHost` プロトコル越しに動く |

---

## 14. 未決事項

PR の「要確認事項」と同じ内容です。決まったらこの章を更新します。

1. **ライセンス**: MIT でよいか。
2. **Swift ツールチェーンの下限**: Swift 6.2（Xcode 26）以降としてよいか。6.0 / 6.1 も対象にする場合、default isolation のテストや `Observations` の扱いが `#if` で複雑になる。
3. **OS の下限**: iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1 でよいか。iOS 18 / macOS 15 以上にすれば `Synchronization.Mutex` に統一できるが、利用者の幅が狭まる。
4. **Action の表現**: `Store<State, Action>` のジェネリクスで enum とプロトコル存在型の両方を許す方針でよいか。
5. ~~**プロパティ単位の追跡（5.4）**~~: 自前の `ObservationRegistrar` とキーパス比較で実現した（M1-5）。
6. **`put` の意味**: reducer の適用完了まで待つ（`await`）方針でよいか。redux-saga の `put` はスケジューリングされるだけで、厳密には異なる。
7. **ターゲット分割**: `Redux` に Slice / Selector / EntityAdapter まで含める（RTK 相当を別ターゲットにしない）方針でよいか。
8. **Example の形式**: `Examples/` 配下にローカルパッケージ（Domain / AppFeature）と Xcode プロジェクト（SwiftUI / UIKit アプリ）を置く方針でよいか。
9. **Linux CI**: UI に依存しないターゲットのビルドとテストを Linux（公式 `swift` コンテナイメージ）でも行う方針でよいか。
