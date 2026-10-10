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
14. [決定事項](#14-決定事項)

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

Swift 6.0 / 6.1 は対象にしないことにしました（[14 章](#14-決定事項)）。

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
├── ReduxTesting     TestStore（Redux + ReduxSaga + SagaTesting）
├── ReduxPersistence State の永続化（Redux + Foundation）
├── ReduxMacros      マクロ（@ActionCases / @Slice）。実装の ReduxMacrosPlugin だけが swift-syntax に依存
└── InternalPrimitives  内部で共有する部品（`Locked` など）。プロダクトにせず `package` アクセスで使う
```

依存関係:

```
Redux ◀── ReduxSaga ──▶ Saga
  ▲                       ▲
  ├── ReduxSwiftUI        └── SagaTesting
  ├── ReduxUIKit
  └── ReduxTesting ──▶ ReduxSaga, SagaTesting
```

- `Saga` は `Redux` に依存しない。Store とは [`SagaHost`](#62-sagahost-プロトコル) という小さなプロトコル越しにつながる。
- `ReduxSwiftUI` / `ReduxUIKit` は `#if canImport(SwiftUI)` / `#if canImport(UIKit)` で囲み、Linux でもパッケージ全体の `swift build` が通るようにする。
- テスト支援は本体と分ける（アプリ本体に XCTest / Testing 依存を持ち込まないため）。テスト支援ターゲットは Swift Testing を import しない（アサーションの失敗は呼び出し側に `throws` で返す）。
- Example は `Examples/` 配下に別パッケージ + Xcode プロジェクトとして置き、ライブラリ本体の依存グラフに含めない。

### プロダクト

各プロダクトは、使うのに必要なターゲットを含める（`ReduxSaga` だけを追加すれば `Redux` と `Saga` も `import` できる）。利用者が用途ごとに 1 つ選べば済むようにするため。

| プロダクト | ターゲット | 用途 |
| --- | --- | --- |
| `Redux` | `Redux` | Redux だけを使う |
| `Saga` | `Saga` | Saga だけを、ほかの状態管理と組み合わせて使う |
| `ReduxSaga` | `Redux`, `Saga`, `ReduxSaga` | Redux と Saga を使う |
| `ReduxSwiftUI` | `Redux`, `ReduxSwiftUI` | SwiftUI のヘルパー |
| `ReduxUIKit` | `Redux`, `ReduxUIKit` | UIKit のヘルパー（watchOS では空） |
| `ReduxMacros` | `Redux`, `ReduxMacros` | マクロ |
| `ReduxPersistence` | `Redux`, `ReduxPersistence` | State の永続化 |
| `SagaTesting` | `Saga`, `SagaTesting` | Saga のテスト |
| `ReduxTesting` | `Redux`, `Saga`, `ReduxSaga`, `SagaTesting`, `ReduxTesting` | Store と Saga のテスト |

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
- 排他制御は `InternalPrimitives` の `Locked<Value>` に集約する。Darwin では `OSAllocatedUnfairLock`、Linux では `Synchronization.Mutex` を使う（`Mutex` は Apple OS では iOS 18 / macOS 15 からのため）。
- 非同期のブリッジ（continuation）は必ずキャンセルハンドラを持ち、キャンセル時に登録を解除して resume する。リークを防ぐため、全 continuation が「ちょうど 1 回 resume される」ことをテストで確認する。

### default MainActor isolation を有効にしたアプリでの利用

ライブラリ自体は default isolation を使わず、公開 API の隔離をすべて明示します（`@MainActor` / `nonisolated` / `@Sendable`）。これにより、利用側の設定に関係なく同じ意味になります。

利用側への注意（README とドキュメントコメントに記載）:

- default MainActor isolation のモジュールで定義した型は暗黙に `@MainActor` になり、`Equatable` などの準拠も MainActor 隔離になる（SE-0470）。Saga はメインアクター外で動くため、**Action / State は `nonisolated` を付けて宣言する**ことを推奨する。
- グローバル変数に置いた reducer も暗黙に `@MainActor` になる。Saga やテストなどメインアクター外から使う場合は `nonisolated let` で宣言する。
- 推奨構成（[11 章](#11-ロックイン回避)）では、Action / Reducer / Saga を置く `AppFeature` ターゲットは default isolation を使わない。

CI では、`.defaultIsolation(MainActor.self)` を設定したテストターゲット `DefaultIsolationTests` で利用コードをコンパイル・実行します（ほかのテストターゲットは default isolation を設定しない）。

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

Action 専用のプロトコル（`protocol Action: Sendable` など）を設けない理由:

- `Saga` は `Redux` に依存しないため、プロトコルを両方で必要とし、別々に定義すると利用側が二重に準拠させることになる。
- ReSwift 用アダプタなどでは Action が `any ReSwift.Action` のような存在型になり、存在型は自前のプロトコルに準拠できないため、Saga のコアで使えなくなる。
- `Equatable` を必須にすると、`case failed(any Error)` のように Equatable でない値を Action に載せられなくなる。比較が必要なテストでは、利用側が `Equatable` に準拠させればよい。

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

`configureStore` 相当として、result builder でまとめて書ける初期化子（`MiddlewareBuilder`）も用意します。

```swift
let store = Store<AppState, AppAction>(initialState: AppState()) {
  Reducer.slice(Counter.self, state: \.counter) { if case .counter(let a) = $0 { a } else { nil } }
  Reducer.slice(Todos.self, state: \.todos) { if case .todos(let a) = $0 { a } else { nil } }
} middleware: {
  sagaMiddleware
  if isDebug {
    LoggingMiddleware()
  }
}
```

（enum の case キーパスがない Swift では、Action の取り出しを `{ if case .counter(let a) = $0 { a } else { nil } }` と書きます。マクロ版で短くします。）

dispatch の処理中に `dispatch` が呼ばれた場合（ミドルウェアや Observation の通知の中から呼ばれた場合）は、その場では処理せずキューに積み、処理中の Action が終わった後に呼ばれた順に処理します。

- 再入をその場で処理しないのは、通知の途中で State が書き換わり、先に呼ばれた Action より後の Action の結果が先に見えてしまうため。
- 再入を禁止（`assertionFailure`）しないのは、SwiftUI / UIKit の Observation の通知からの dispatch は利用側で避けにくく、禁止すると実用上困るため。
- reducer は Store を参照できない `@Sendable` の純粋関数なので、reducer の中からの dispatch は型の上で起こらない。

#### 機能ごとの Store（scope）

機能ごとのモジュールの View / ViewModel が、アプリ全体の `AppState` / `AppAction` を知らずに書けるよう、State と Action の一部だけを扱う Store を作れるようにする（Reducer の `scope`、Saga の接続（6.9）と同じ考え方）。

```swift
extension Store {
  public func scope<ChildState, ChildAction>(
    state: KeyPath<State, ChildState>,                    // 関数版もある
    action embed: @escaping (ChildAction) -> Action
  ) -> Store<ChildState, ChildAction>
}

let todoStore = store.scope(state: \.todo, action: AppAction.todo)   // Store<TodoFeature.State, TodoFeature.Action>
```

- 作った Store は同じ `Store` 型なので、`@Environment`、`binding`、`observe` などがそのまま使える。
- 作った Store は State の写しを持ち、親が State を更新したときに、親から子の State を取り出して同じ手順（5.4 の新旧の比較と通知）で更新する。読み取りの追跡は子でもプロパティ単位になる。親の State が変わらなかったときは子に知らせない。
- dispatch は `embed` で包んで親に送る。子はミドルウェアと reducer を持たない。
- 子は親を強参照し（子を使っている間は親が残る）、親は子を弱参照する（使い終わった子は解放され、親は知らせる先から外す）。
- 子を親の State へのキーパスで追跡する方式（親の registrar に合成したキーパスで登録する）は採らない。合成したキーパスは `Sendable` を静的に示せず、子の `TrackedState` の追跡も作り直しになるため。

### 5.4 Observation の追跡単位（プロパティ単位の再描画）

`@Observable` のマクロで `state` プロパティを追跡するだけだと、`store.state.count` を読んだ View は State のどのプロパティが変わっても再描画されます。プロパティ単位の追跡のために、Store は `ObservationRegistrar` を自前で管理します。

- `store.count`（dynamic member）を読むと、`\Store.state` にキーパス `\State.count` をつないだキーパスをアクセスとして登録する。
- 登録時に、そのキーパスの新旧の値を比較するクロージャ（`Value: Equatable` を使う）を Store 内の表に記録する。
- `dispatch` で reducer を適用した後、表にあるキーパスについて新旧の値を比較し、変わったものだけ `willSet` / `didSet` を通知する。変わったキーパスがすべて `willSet` → 代入 → すべて `didSet` の順にする。
- `store.state` を直接読んだ場合は `\Store.state` 全体の変更として通知する。State が `Equatable` なら、変化がないときは通知しない。
- 値が `Equatable` でないプロパティを dynamic member で読んだ場合は、`\Store.state` 全体の変更として扱う。
- 追跡の単位は Store から直接読んだプロパティ。`store.profile.name` は `profile` の変化で通知される（`name` 以外が変わっても通知される）。`Profile` に `@TrackedState` を付けると `name` 単位になる（下記）。

#### ネストしたプロパティ単位の追跡（`@TrackedState`）

State の中にネストした struct に `ReduxMacros` の `@TrackedState` を付けると、`store.profile.name` は `name` が変わったときだけ通知されます。

```swift
@TrackedState
struct Profile: Sendable, Equatable {
  var name: String = ""
  var address: Address = Address()   // Address も @TrackedState なら、さらに中まで追跡する
}
```

仕組み:

- `store.profile`（値が `TrackedState`）は、値のコピーに「読み取り元」（`StateTrackingContext`：State からのキーパスと、Store に知らせる関数）を付けて返す。この時点では `profile` 全体を追跡に登録しない。
- マクロは保存プロパティを、裏の保存プロパティ（`_name`）と、読み取りを知らせる計算プロパティに分ける（`init` アクセサで memberwise init はそのまま使える）。`name` を読むと `\State.profile.name` が Store に知らされ、Store はそのキーパスの新旧の値を比べて、変わったときだけ通知する。
- 通知の単位には、State 上のキーパスを添字に持つ Store のキーパス（`\Store[trackedPath:]`）を使う。`ObservationRegistrar` は通知の単位を Store 上のキーパスで区別するため。
- 読み取りは値のコピーから行われ、メインアクター外で起き得るため、ネストしたキーパスの表は `Locked` で守る。
- 「読み取り元」は `Equatable` / `Hashable` で常に等しく扱い、値の比較に影響させない。Optional にしないのは、Optional だと「読み取り元の有無」が比較されてしまうため。

制限:

- 値全体を比較したり受け渡したりするだけでは追跡されない。読んだプロパティだけが追跡される（`store.state` を経由した読み取りは従来どおり State 全体を追跡する）。
- 対象は型を書いた `var` の保存プロパティ（計算プロパティは中で読んだ保存プロパティが追跡される）。
- `let` やプロパティラッパー付き（`@BindableState` など）のプロパティは、アクセサを付けられず追跡の仕組みを入れられない。マクロはそれらを持つ型に `_$hasUntrackedProperties = true` を生成し、Store はその型の値全体の変化でも通知する（通知の漏れを防ぐため。細かさは落ちる）。
- `Codable` の自動準拠ではキーが `_name` になるので、`CodingKeys` を書く。

比較のコストは「参照されていて、まだ値が変わっていないキーパスの数」に比例します。

- 値が変わって通知したキーパスは、通知する前に表から外す。Observation の購読は 1 回通知されると外れ、通知を受けた側が読み直したときに登録し直されるため、外しても通知は漏れない。外さないと、`\.items[id: id]` のように値ごとに異なるキーパスが、過去に表示した件数だけ溜まり、dispatch のたびに比べ続けることになる。
- 値が変わらないまま読まれなくなったキーパス（削除済みの要素を読んだ `nil` など）は、変化の通知では外れない。そこで、表の大きさ（最低 256）ごとの更新の回数ごとに、前回の掃除から一度も読まれていないキーパスを、通知してから外す。購読がまだ残っているかは Observation から分からないため、通知して、まだ読んでいる側には読み直してもらう（その読み取りで登録し直される）。読み直しは、値が変わらないまま読まれ続けるキーパスにつき、表の大きさ程度の更新ごとに 1 回で、更新 1 回あたりの手間は一定に収まる。
- State が `Equatable` で変わっていなければ、どのキーパスも比べない。
- scope で作った子の Store に知らせるときは、子の一覧の写しを回す。知らせた先（Observation の通知）で `scope` が呼ばれて一覧に追加されても、回している最中の一覧を書き換えないため。

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

組み込みのミドルウェアとして `LoggingMiddleware` を用意します。

```swift
public struct LoggingMiddleware<State, Action>: Middleware {
  public init(
    isEnabled: Bool? = nil,          // 省略するとデバッグビルドでだけ出力する
    logsState: Bool = false,         // 適用後の State も出すか
    privacy: Privacy = .private,     // .private / .public
    subsystem: String = "swift-redux-saga", category: String = "Redux",
    filter: @escaping @Sendable (Action) -> Bool = { _ in true })
}
```

- Apple OS では `os.Logger` の `debug` レベルで出力する（`print` を使わないのは、Console.app でフィルタでき、リリースビルドの負荷やログへの残り方を OS に任せられるため）。それ以外の OS では標準出力。
- 値は既定で `.private`。Action や State は個人情報を含み得るため。

### 5.6 Slice（`createSlice` 相当）

Swift では enum の case が「Action 作成関数」の役割を果たすため、Slice は State・Action・reducer を 1 つの名前空間にまとめるプロトコルとして定義します。

```swift
public protocol Slice: SendableMetatype {
  associatedtype State: Sendable
  associatedtype Action: Sendable
  static var initialState: State { get }
  static func reduce(into state: inout State, action: Action)
}

extension Slice {
  public static var reducer: Reducer<State, Action> { get }
}

extension Reducer {
  /// Slice の reducer を親に持ち上げる（scope の Slice 版）。
  public static func slice<S: Slice>(
    _ slice: S.Type,
    state: WritableKeyPath<State, S.State> & Sendable,
    action: @escaping @Sendable (Action) -> S.Action?
  ) -> Reducer
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

- `SendableMetatype` を要求するのは、reducer（`@Sendable`）の中から Slice の `static func` を呼ぶため。default MainActor isolation のモジュールでは `nonisolated enum Counter: Slice` と宣言する。

### 5.7 Selector（`createSelector` 相当）

入力セレクタの結果が前回と同じ（`Equatable`）なら、前回の出力を返します。パラメータパックで入力セレクタの数を任意にします。

```swift
public struct Selector<State: Sendable, Output: Sendable>: Sendable {
  public init(_ select: @escaping @Sendable (State) -> Output)   // メモ化しない
  public func callAsFunction(_ state: State) -> Output
}

public func createSelector<State: Sendable, each Input: Equatable & Sendable, Output: Sendable>(
  _ inputs: repeat @escaping @Sendable (State) -> each Input,
  result: @escaping @Sendable (repeat each Input) -> Output
) -> Selector<State, Output>

let visibleTodos = createSelector(\AppState.todos, \.filter) { todos, filter in ... }
```

- キャッシュは Saga（メインアクター外）からも使われるため、`Locked` で保護する。キャッシュサイズは 1（RTK の既定と同じ）。`result` はロックの外で呼ぶ。
- 入力はパラメータパックのまま保持せず、型を消した配列にして比較する。パックを持つジェネリック型の保存で Swift 6.3 のコンパイラがクラッシュするため。
- クロージャで入力を渡す場合、State の型を推論できないことがあるため、キーパスで渡すか型を書く。

### 5.8 Entity Adapter（`createEntityAdapter` 相当）

```swift
public struct EntityState<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  public var ids: [ID]
  public var entities: [ID: Entity]
  public init()
}
extension EntityState: Equatable where Entity: Equatable {}

public struct EntityAdapter<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  public init(id: @escaping @Sendable (Entity) -> ID, sortedBy: (@Sendable (Entity, Entity) -> Bool)? = nil)

  public func addOne(_:to:) / addMany(_:to:)        // 同じ ID があれば追加しない
  public func setOne(_:in:) / setMany(_:in:)        // 追加か置き換え（RTK の setOne / upsertOne）
  public func setAll(_:in:)
  public func updateOne(_ id:in:_ update: (inout Entity) -> Void) / updateMany(...)
  public func removeOne(_:from:) / removeMany(_:from:) / removeAll(from:)

  public func all(in:) -> [Entity]
  public func entity(_ id:in:) -> Entity?
  public func count(in:) -> Int
}

extension EntityAdapter where Entity: Identifiable, ID == Entity.ID {
  public init(sortedBy: ...)
}
```

- `updateOne` で ID を変えた場合は新しい ID で持ち直す。新しい ID がすでにあれば置き換え、`ids` に同じ ID を並べない（RTK と同じ）。
- RTK の `upsertOne` は部分的な更新をマージするが、Swift には部分型がないため、置き換え（`setOne`）と、クロージャで書き換える `updateOne` に分ける。
- 並び順を指定した場合は、変更のたびに `ids` を並べ直す。

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
  /// Store 以外（MVVM の ViewModel など）の Observable な値も同じ仕組みで購読する。
  public static func observe<Value>(_ read: @escaping @MainActor () -> Value,
                                    onChange: @escaping @MainActor (Value) -> Void) -> ObservationToken
}
```

- 変化の通知は、変更が終わった後にメインアクター上で非同期に届く。`withObservationTracking` の onChange は変更の直前に呼ばれ、新しい値を読めないため。続けて変更された場合は最後の値だけが届くことがある。
- iOS 26 以降でも `Observations` を使わず、同じ実装を使う。OS によって通知のタイミングが変わらないようにするため。iOS 26 以降のアプリは `Observations { store.count }` を直接使ってもよい（Store は `Observable` なので、そのまま動く）。
- 購読は Store とトークンを弱参照で持ち、Store や呼び出し元を延命しない。

### 5.10 入力欄の Binding（BindableState / BindingAction）

`TextField` や `Toggle` など、ユーザーが値を直接変える UI 部品のために、値を書き戻すだけの Action と reducer を部品ごとに書かなくて済むようにします。

```swift
@propertyWrapper public struct BindableState<Value> { public var wrappedValue: Value; public var projectedValue: Self }

public struct BindingAction<State: Sendable>: Sendable, Equatable {
  public static func set<Value: Equatable & Sendable>(
    _ keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable, _ value: Value) -> Self
  public func apply(to state: inout State)
  public func value<Value>(for keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable) -> Value?
}

public protocol BindableAction: Sendable {
  associatedtype State: Sendable
  static func binding(_ action: BindingAction<State>) -> Self   // case binding(BindingAction<State>) で満たす
  var binding: BindingAction<State>? { get }                    // @ActionCases が生成する
}

extension Reducer where Action: BindableAction, Action.State == State {
  public static var binding: Reducer   // BindingAction を適用する
}
// ReduxSwiftUI
extension Store where Action: BindableAction, Action.State == State {
  public func binding<Value: Equatable & Sendable>(_ keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable) -> Binding<Value>
}
extension Store {
  // Optional の値（ID で読んだ一覧の要素のプロパティなど）の Binding。nil のときは defaultValue
  public func binding<Value: Equatable>(_ keyPath: KeyPath<State, Value?> & Sendable, default defaultValue: Value, send: @escaping (Value) -> Action) -> Binding<Value>
}
// Redux: 一覧の要素を ID で読み書きする（添字のキーパスは要素の削除で範囲外になり、Store が変化を判定するときに停止するため）
extension Array where Element: Identifiable {
  public subscript(id id: Element.ID) -> Element? { get set }   // nil を書くと削除、なければ末尾に追加
}
// ReduxSaga（Saga は Redux に依存しないため、Redux の型を使うパターンはここに置く）
extension ActionPattern where Action: BindableAction {
  public static func binding(_ keyPath: WritableKeyPath<Action.State, BindableState<Value>> & Sendable) -> Self
}
```

```swift
struct State: Sendable, Equatable {
  @BindableState var draft = ""   // 入力欄から書き換えてよいプロパティに印を付ける
  var todos: [Todo] = []          // 印のないプロパティは BindingAction で書き換えられない
}
enum Action: Sendable, BindableAction {
  case binding(BindingAction<State>)
  case addTapped
}
TextField("New ToDo", text: store.binding(\.$draft))
ctx.debounce(.milliseconds(300), .binding(\.$query)) { ctx, query in ... }
```

- マクロではなくプロパティラッパーにしたのは、書き換えてよいプロパティを型で区別でき、マクロなしでも使えるため。`var binding` は `@ActionCases`（`@Slice` の Action には自動で付く）が生成し、マクロを使わない場合は手書きする。
- 書き換えてよいプロパティを印で限定するのは、View から任意の State を書き換えられると、reducer を通さない変更が増えて追いにくくなるため。

### 5.11 State の永続化（`ReduxPersistence`）

State のうち保存したい部分（`Codable` なスナップショット）を保存し、起動時に復元します。Foundation（JSON・ファイル・UserDefaults）を使うため、`Redux` 本体とは別のターゲットにします。

```swift
public protocol PersistenceStorage: Sendable {
  func load(key: String) throws -> Data?
  func save(_ data: Data, key: String) throws
  func remove(key: String) throws
}
// 用意する保存先: UserDefaultsStorage / FileStorage / InMemoryStorage

public struct Persistence<State: Sendable, Snapshot: Codable & Sendable>: Sendable {
  public init(key:storage:version:snapshot:apply:migrate:)
  public init(key:storage:version:keyPath:migrate:)            // State のプロパティを保存
  public func restore(into state: State, onError:) -> State    // 復元（失敗したら state のまま）
  public func save(_ state: State) throws
  public func clear() throws
}

@MainActor
public final class PersistenceMiddleware<State, Action>: Middleware {
  public init(_ persistence: Persistence<State, Snapshot>, debounce: Duration = .milliseconds(500),
              clock: any Clock<Duration> = ContinuousClock(), onError:)
  public func flush() async   // 待っている保存をすぐ行う（バックグラウンドに入るときなど）
}
```

```swift
let persistence = Persistence<AppState, Settings>(key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)
let store = Store(
  initialState: persistence.restore(into: AppState()),
  reducer: appReducer,
  middleware: [PersistenceMiddleware<AppState, AppAction>(persistence)])
```

- 保存形式は `{"version": n, "snapshot": ...}` の JSON。バージョンが違えば `migrate` に古いスナップショットの JSON を渡す（変換できなければ復元しない）。
- 保存は、スナップショットが変わったとき（`Equatable` なら比較する）に、最後の変化から `debounce` 後に 1 回だけ行う。エンコードと書き込みは `Task.detached` でメインアクターの外で行う。
- 保存が重なったときは、前の保存の書き込みが終わってから書く（古い State が後から書かれて残らないようにする）。`flush()` は書き込み中の保存の終わりも待つ。
- アプリは、バックグラウンドに入るときに `flush()` を呼ぶ（`debounce` の間に終了されると保存されないため）。
- Saga ではなくミドルウェアにするのは、Saga を使わないアプリでも使えるようにするため。
- 保存するのは、設定や下書きなど保存してよいものに絞る。読み込み中やエラーのような一時的な状態は保存しない。

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

```swift
public final class SagaRuntime<State: Sendable, Action: Sendable>: Sendable {
  public init<Host: SagaHost>(host: Host, clock: any Clock<Duration> = ContinuousClock())
    where Host.State == State, Host.Action == Action
  /// Host が処理した Action を、その時点で待っている Saga に届ける。
  public func emit(_ action: Action)
  /// Saga を起動する（Saga の木の根）。
  @discardableResult public func run(_ saga: Saga<State, Action>) -> SagaTask
  /// 起動したすべての Saga をキャンセルする。以降に run した Saga はすぐにキャンセルされる。
  public func stop()
}

public struct SagaTask: Sendable, Hashable {
  public var isRunning: Bool { get }
  public var isCancelled: Bool { get }
  public func cancel()
  /// Saga の外から待つ。Saga の中では `ctx.join(task)` を使う。
  public func join() async throws
}
```

- `run` だけは非構造化の `Task` で根を作る（親になるタスクが存在しないため）。根より下はすべてタスクグループの子タスク。
- キャンセルを受けた Saga が `CancellationError` を catch して正常に終わっても、キャンセルとして扱う（redux-saga と同じ）。
- `join` を Saga の中用（`ctx.join`）と外用（`SagaTask.join`）に分けるのは、テスト支援のために「Saga が Effect で止まっているか」を数えており（9 章）、外から待つ側を数えないため。

### 6.3 Saga と SagaContext

Saga は「コンテキストを受け取る async 関数」です。旧実装のように Action を引数に取りません。

```swift
public struct Saga<State: Sendable, Action: Sendable>: Sendable {
  public init(_ body: @escaping @Sendable (SagaContext<State, Action>) async throws -> Void)

  /// 現在のコンテキストで本体を実行する（ほかの Saga の中から呼び出す場合）。
  public func run(_ context: SagaContext<State, Action>) async throws

  /// 複数の Saga を並行に実行する（それぞれを fork する）。
  public static func combine(_ sagas: Saga..., name: String? = nil) -> Saga
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

`Saga` 型には、複数の Saga をまとめる `Saga.combine(_:name:)`（それぞれを fork する）も用意し、上の組み立てを `Saga.combine(userSagas.root, todoSagas.root)` と書けるようにします。

### 6.4 Action のマッチング

```swift
public struct ActionPattern<Action: Sendable, Value: Sendable>: Sendable {
  public init(_ extract: @escaping @Sendable (Action) -> Value?)

  /// enum の case などから値を型付きで取り出す（init と同じ）。
  public static func `case`(_ extract: @escaping @Sendable (Action) -> Value?) -> Self
  /// 型による判定（`Action` がプロトコル存在型のとき用）。`as?` でキャストする。
  public static func type(_ type: Value.Type) -> Self
  /// いずれかに一致する（先に書いたものを優先）。
  public static func oneOf(_ patterns: Self...) -> Self

  public func match(_ action: Action) -> Value?
  /// 取り出した値が条件を満たすときだけ一致する。
  public func `where`(_ predicate: @escaping @Sendable (Value) -> Bool) -> Self
}

extension ActionPattern where Value == Action {
  public static var any: Self { get }
  public static func filter(_ predicate: @escaping @Sendable (Action) -> Bool) -> Self
}

extension ActionPattern where Value == Action, Action: Equatable {
  /// 等しい Action に一致する（`.action(.logout)`）。
  public static func action(_ expected: Action) -> Self
}
```

`SagaContext` の各 Effect は `ActionPattern` を受け取り、取り出した `Value` を返します。enum の case から値を取り出すクロージャはマクロ版で生成できるようにします（[12 章](#12-マクロ任意)）。

### 6.5 Effect 一覧

| redux-saga | Swift API（案） | 補足 |
| --- | --- | --- |
| `take` | `func take<V>(_ p: ActionPattern<Action, V>) async throws -> V` | 次に来た一致する Action を待つ |
| `put` | `func put(_ action: Action) async` | reducer 適用後に戻る |
| `select` | `func select<T: Sendable>(_ s: @Sendable (State) -> T) async -> T` / `func select() async -> State` | |
| `call` | `func call<each A: Sendable, R: Sendable>(_ f: @Sendable (repeat each A) async throws -> R, _ args: repeat each A) async throws -> R` | 任意の async 関数を呼ぶ。呼ぶ前と戻った後にキャンセルを確認する（キャンセル後の結果もエラーも返さず、`CancellationError` を投げる） |
| `fork` | `func fork(_ saga: Saga) -> SagaTask` / `func fork(_ name: String?, _ body:) -> SagaTask` | attached。親のキャンセルが伝播し、子のエラーは親に伝播する |
| `spawn` | `func spawn(_ saga: Saga) -> SagaTask` / `func spawn(_ name: String?, _ body:) -> SagaTask` | detached。ランタイム停止時のみキャンセルされる |
| `cancel` | `ctx.cancel(_ task:)` / `SagaTask.cancel()` | 子をキャンセルしても親にエラーは伝わらない |
| `join` | `ctx.join(_ task: SagaTask) async throws` | Saga の外からは `SagaTask.join()` |
| `cancelled` | `ctx.isCancelled` / `Task.isCancelled` | |
| `delay` | `func delay(_ duration: Duration) async throws` | ランタイムに注入した `Clock` を使う |
| `takeEvery` | `func takeEvery<V>(_ p, _ worker: (SagaContext, V) async throws -> Void) -> SagaTask` | 非ブロッキング（内部で fork）。ワーカーは並行に動く |
| `takeLatest` | `func takeLatest<V>(_ p, _ worker) -> SagaTask` | 前回のワーカーをキャンセルしてから起動 |
| `takeLeading` | `func takeLeading<V>(_ p, _ worker) -> SagaTask` | 最初の Action を受け取った時点で実行枠を予約し、ワーカーの実行が終わるまで追加の Action は捨てる |
| `debounce` | `func debounce<V>(_ d: Duration, _ p, _ worker) -> SagaTask` | 静かな期間の後に最後の Action で起動。起動したワーカーは後の Action でキャンセルしない |
| `throttle` | `func throttle<V>(_ d: Duration, _ p, _ worker) -> SagaTask` | 起動後 `d` の間は最新の 1 件だけ残し、`d` の後に処理する |
| `all` | `func all<each R>(_ ops: repeat @Sendable (SagaContext) async throws -> each R) async throws -> (repeat each R)` | 各処理は fork した子で、自分の ctx を受け取る。1 つでも失敗したら他をキャンセルし、エラーは呼び出し元で catch できる（処理の中で fork した子の失敗も含む）。1 つでもキャンセルで終わったら、他をキャンセルして `CancellationError` を投げる |
| `race` | `func race<each R>(_ ops: repeat @Sendable (SagaContext) async throws -> each R) async throws -> (repeat (each R)?)` | 最初に終わったもの以外はキャンセル。戻り値は勝者のみ非 nil。勝者が失敗したらそのエラー、キャンセルで終わったら `CancellationError` を投げる |
| `actionChannel` | `func actionChannel<V>(_ p, buffer: ChannelBuffer = .unbounded) -> SagaChannel<V>` | 作った時点から溜める。作った Saga が終わると閉じる |
| `eventChannel` | `func eventChannel<V>(buffer:, _ subscribe: (emit, EventChannelFinish) -> unsubscribe) -> SagaChannel<V>` / `func eventChannel(buffer:, from: some AsyncSequence)` | 閉じると unsubscribe を呼ぶ。作った Saga が終わると閉じる。イベント源がエラーで終わる（`finish(throwing:)`、シーケンスのエラー）と、溜まった値の後に受け取り側でそのエラーを投げる |

```swift
public enum ChannelBuffer: Sendable { case unbounded, newest(Int), oldest(Int) }

/// 複数の Saga から読める（待ち始めた順に渡す）。AsyncSequence なので for try await で読める。
public struct SagaChannel<Value: Sendable>: Sendable, AsyncSequence {
  public func take() async throws -> Value?   // 閉じられて空なら nil
  public func close()
}
```

- チャネルの `take` / iteration は、受け取り側がキャンセル済みなら、バッファの値や終了理由を消費せず `CancellationError` を投げる。閉じたチャネルも同じで、残りの値やエラーはキャンセルされていない受け取り側へ渡す。
- チャネルは作った Saga の終了で自動的に閉じる。閉じ忘れによる購読のリークを防ぐため（redux-saga では明示的に閉じる必要がある）。
- `eventChannel(from:)` のシーケンスの読み取りは、チャネルが持つ非構造化の `Task` で行う。外部のイベント源の寿命が Saga の木と一致しないため。チャネルが閉じたらキャンセルする。

`call` を使わず `try await useCase.execute(id)` と直接書いても動きます。`call` を使うと、呼び出し前のキャンセル確認と、モニタ（[8 章](#8-エラー処理)）への記録が行われます。

### 6.6 fork / spawn の実装方針（構造化並行性）

- 各 Saga は「スコープ」を持つ。スコープは `withThrowingDiscardingTaskGroup` を開き、Saga 本体と fork された子をすべてそのグループの子タスクとして実行する。
- `fork` は同期関数。スコープが持つ要求キュー（`ForkQueue`）に子の起動要求を積み、グループ側のループがそれを `addTask` する。したがって子は親タスクの本物の子タスクであり、親のキャンセルは自動で伝播する。
  - キューに `AsyncStream` を使わないのは、親がキャンセルされると iteration が終わり、積まれた要求が起動されずに残る（join した側が永久に待つ）ため。`ForkQueue` はキャンセルされても閉じられるまで要求を渡す。
- 親（Saga 本体）は、本体が終わってもすべての子が終わるまで完了しない（redux-saga と同じ）。
- 子が未処理のエラーで終わるとグループが失敗し、兄弟と親がキャンセルされ、エラーが親に伝播する。
- 個々の子を `SagaTask.cancel()` で止めるため、子は自分用のキャンセル信号（`CancelSignal`）を持ち、内側のタスクグループで本体と信号の待機を競わせる。信号が先に来たら本体をキャンセルし、本体の結果を待ってから終わる（待たずに抜けると、本体の `CancellationError` が捨てられて完了と区別できないため）。
- 子のキャンセル（個別のキャンセル、親からのキャンセル）は親にエラーとして伝えない。子の失敗だけを伝える。
- `spawn` はランタイムが持つルートスコープに子を追加する。呼び出し元の親とは切り離されるが、ランタイムの停止（Store の破棄など）でキャンセルされる。`Task.detached` は使わない。

### 6.7 take の配信方式

- ランタイムは `ActionMulticaster` を持ち、`emit` された Action を、その時点で登録されている taker（`take` 待ち）とチャネルに配る。
- `take` は 1 回限りの taker を登録して待つ。キャンセルされたら登録を外して `CancellationError` を投げる。購読が溜まることはない。
- `take` を繰り返すループでは、ワーカーの実行中に来た Action は受け取れない（redux-saga と同じ）。取りこぼしたくない場合は `actionChannel` か `takeEvery` を使う。
- `takeEvery` などのヘルパーは、呼び出した時点で購読（内部のチャネル）を始め、取りこぼさない。チャネルはヘルパーの終了時に閉じ、購読を外す。
- `takeLeading` は、購読開始からワーカーの起動までの最初の Action も受け付ける。受信時に実行枠を予約し、ワーカーの終了で解放する。予約した 1 件だけを内部チャネルで保持し、予約中の追加の Action は溜めない。
- 内部のチャネルに `AsyncStream` を使わないのは、受け取り側の再開を Activity で数える必要があるため（値を渡す側が数える）。

### 6.8 時間

`SagaRuntime` は `any Clock<Duration>` を受け取ります（既定は `ContinuousClock`）。`delay` / `debounce` / `throttle` はこの Clock を使うため、テストでは `TestClock` に差し替えて時間を進められます。

### 6.9 機能ごとの Saga の接続（scope）

機能ごとにモジュールを分けるアプリでは、`Saga<Todo.State, Todo.Action>` と `Saga<Auth.State, Auth.Action>` を親の `Saga<AppState, AppAction>` で動かしたい。Reducer の `scope` と同じく、子の型のまま親に接続する。

```swift
// ランタイム / SagaMiddleware: 起動時に接続する
runtime.run(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)
// Saga の中: 子として接続する（呼び出し元のキャンセルで止まる。ログイン中だけ動かすなど）
let session = ctx.fork(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)
```

- ランタイムは分けず、1 つのランタイムの中で、Saga から見た State・Action の読み書きの相手（環境）だけを子の型に付け替える。子の Host は親の Host を通して `state` で子の State を読み、`embed` で包んだ親の Action を発行する。子の `take` / 購読は、親の Action の配信から `action` で取り出したものを受け取る。
- そのため、scope を通しても通さなくても、fork / spawn / キャンセル / join / エラーの伝わり方は同じになる。子が `spawn` した Saga もランタイムの根として管理され、`stop()` で止まり、Action を受け取り続ける。`ctx.fork` で接続した子の失敗は、通常の `fork` と同じく呼び出し元に伝わり、呼び出し元の `join` は子の後始末が終わるまで戻らない。
- `SagaContext` はランタイムの具体型を持たず、State・Action に依存しない実行の仕組み（`SagaEngine`: 子の起動、終わり方の確定、Activity、時計、モニタ）と、型付きの環境を持つ。
- 接続ごとに子のランタイムを作る方式は採らない（最初の実装はこの方式だった）。子のランタイムの寿命を別に管理する必要があり、子の根が終わった後の `spawn` が管理から外れる、`fork` の終わり方と子の後始末がずれる、などの食い違いが起きたため。

---

## 7. Redux と Saga の接続

`ReduxSaga` ターゲットが提供します。

```swift
@MainActor
public final class SagaMiddleware<State: Sendable, Action: Sendable>: Middleware {
  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    monitor: (any SagaMonitor)? = nil,
    onError: @escaping @Sendable (SagaError) -> Void = SagaRuntime<State, Action>.logError
  )

  /// ルート Saga を起動する。Store の生成後に呼ぶ。
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask

  /// すべての Saga が Effect で止まるまで待つ。
  public func waitUntilIdle() async

  /// すべての Saga をキャンセルする。
  public func stop()
}
```

- `handle` では `next(action)`（reducer 適用）の後に `runtime.emit(action)` を呼ぶ。redux-saga と同じく、Saga が受け取るのは reducer 適用後の Action。
- Host（Store 側の窓口）は `MiddlewareAPI` 経由で Store を弱参照する。Store が解放されるとミドルウェアも解放され、`deinit` でランタイムを停止する。Store ⇄ ミドルウェア ⇄ ランタイムの循環参照は作らない。Store の解放後に `select` された場合は、最後の State を返す。
- `put` は `await MainActor.run { store.dispatch(action) }` 相当。Store の dispatch は同期なので、戻った時点で reducer の適用が終わっている。

### 起動直後の Action（redux-saga との違い）

redux-saga の `run` は、ルート Saga を最初の Effect まで同期に進めてから戻ります。Swift では async 関数を同期に進められないため、`run` から Saga は非同期に動き出します。そのままでは、起動直後（View の表示時など）に dispatch した Action が、まだ `take` で待ち始めていない Saga に届かず、黙って失われます。

そこで、redux-saga の「最初の Effect まで進めてから戻る」に合わせて、起動中の Action を溜めて後から届けます。

- 最初の `run` から、その間に起動した Saga（`run` / `fork` / `spawn`）がすべて最初の待つ Effect（`take` / `put` / `select` / `call` / `join` / `delay`）か終わりに達するまでを「起動中」とする。
- 起動中に emit された Action は溜めておき、起動中が終わった時点で順に届ける。`take` は待ち始めた（登録した）後に達したとみなす。
- `fork` / `spawn` / `cancel` は待たずに続きを実行するので、達したとみなさない。`takeEvery` などのヘルパーは呼び出した時点で購読を始めているので、ヘルパーの子は待たない。
- 起動時に長い `call`（通信など）を行っても、その `call` に達した時点で起動中は終わるので、ほかの Action は遅れない。
- チャネルの読み取りのように Effect を通らずに待つ Saga があっても溜め続けないよう、すべての Saga が止まったとき（Activity が 0 になるとき）にも届ける。
- 溜めるのは最初の `run` の起動中だけ。起動後に `run` した Saga は、redux-saga と同じく、待ち始める前の Action を受け取らない。

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
  public let underlying: any Error
  /// エラーが伝播した Saga の経路（起きた Saga から根に向かう順。名前のない Saga は "anonymous"）。
  public let sagaStack: [String]
}

public struct SagaID: Sendable, Hashable { }
public enum SagaResult: Sendable { case completed, cancelled, failed(any Error) }
public enum SagaEffect: Sendable {
  case take, put(String), select, call, fork(SagaID), spawn(SagaID), join(SagaID), cancel(SagaID), delay(Duration)
}

public protocol SagaMonitor: Sendable {
  func sagaStarted(_ id: SagaID, name: String?, parent: SagaID?)
  func sagaFinished(_ id: SagaID, result: SagaResult)
  func effectTriggered(_ id: SagaID, effect: SagaEffect)
}
```

- `SagaRuntime.init(host:clock:monitor:onError:)` で `onError` と `monitor` を渡す。
- `SagaTask.join()` / `ctx.join(_:)` が投げるのは元のエラー（`SagaError` で包まない）。経路が分かるのは `onError` だけ。join する側が元のエラーの型で `catch` できるようにするため。
- `SagaEffect.put` が Action を文字列で持つのは、モニタを Action の型に依存させず、`Sendable` でない `Any` を持たないため。
- 既定の `onError`（`SagaRuntime.logError`）は、Apple OS では `os.Logger`、それ以外では標準出力にログを出す。
- `SagaMonitor` はログ出力やデバッグツール用のフック。テスト支援もこれを使う。

---

## 9. テスト支援

Swift にはジェネレーターがないため、redux-saga の「Effect を 1 ステップずつ取り出して検証する」テストは再現しません。代わりに、Saga を実際に動かして**結果（発行された Action と State）を検証する**テストを書きやすくします。この違いは README に明記します。

```swift
@Test func fetchUser() async throws {
  let tester = SagaTester(
    initialState: AppState(),
    reduce: appReducer.reduce,
    saga: UserSagas(fetchUserUseCase: StubFetchUserUseCase(User(id: 1))).root
  )

  await tester.send(.user(.fetch(1)))
  try tester.receive(.user(.fetched(User(id: 1))))   // Action が Equatable の場合
  #expect(tester.state.user == User(id: 1))
  try await tester.finish()   // 確かめていない Action や未処理のエラーがないこと
}
```

| 型 | ターゲット | 役割 |
| --- | --- | --- |
| `TestClock` | `SagaTesting` | 手動で進める `Clock`。`advance(by:)` / `advance(to:)` |
| `SagaTester` | `SagaTesting` | Store なしで Saga を動かす。`send` / `receive` / `advance(by:)` / `settle` / `finish` |
| `SagaTesterFailure` | `SagaTesting` | 検証の失敗。テスト支援は Swift Testing を import せず、失敗を `throws` で返す |
| `TestStore` | `ReduxTesting` | 本物の `Store` + ミドルウェア（Saga を含む）を動かし、`send(_:assert:)` で reducer 直後の State を、`receive(_:assert:)` で Saga などが dispatch した Action とその後の State を順に検証する。通信が重なる場面は、待たずに送る `dispatch(_:assert:)` と、届くまで待つ `receive(_:timeout:assert:)` で検証する（`SagaTester` も同じ） |
| `TestStoreFailure` | `ReduxTesting` | 検証の失敗 |

### フレーキーにしないための仕組み

時間や `Task.yield()` の回数に頼らないため、ランタイムは「Effect で止まっていない Saga の数」（`Activity`）を数えます。`settle()` はこの数が 0 になるまで待ちます。`send` / `advance(by:)` は内部で `settle()` を呼びます。

- Saga の本体が動いている間と、本体が終わってから終わり方が確定する（finish）までの後始末を数える。
- `take` / `delay`（`TestClock` のとき）/ `join` で止まる直前に減らし、**再開させる側**が resume の直前に増やす。再開される側で増やすと、resume から動き出すまでの間に 0 と誤判定するため。
- `delay`（`TestClock` のとき）は、時計に眠りを登録した直後に減らす。登録の前に減らすと、減らしてから登録するまでの間に 0 と判定され、テストが時計を進め終えた後に登録された眠りが起こされずに残るため。
- キャンセルの要求、子の失敗、最後の子の終了は、対象の Saga の後始末の分を先に数えてから自分の分を減らす。キャンセルや失敗の伝播の途中で 0 にならないようにするため。
- 起動中に溜めた Action（7 章）は、数が 0 になるときに、1 つ数えたまま届ける。届け終わる前に `settle()` が戻らないようにするため。
- `call` で呼んだ関数の実行中は数える。終わらない関数（実際の通信など）を呼ぶと `settle()` も終わらないので、テストではスタブを渡す。
- `TestClock` 以外の時計（実時間）で `delay` している間は数えない。眠る直前に減らし、起きた Saga が自分で増やす（起こす側に手を入れられないため）。数えると、`delay` を繰り返す Saga があるだけで `waitUntilIdle()` が戻らなくなる。

## 10. SwiftUI / UIKit 連携

### SwiftUI（`ReduxSwiftUI`）

- `Store` は `Observable` なので、`@State` / `@Environment` でそのまま扱える。View の中で `store.count` のように読むと、そのプロパティだけが追跡される（5.4）。
- ヘルパー:

```swift
extension Store {
  /// State の値と、値が変わったときに dispatch する Action から Binding を作る。
  public func binding<Value: Equatable>(
    _ keyPath: KeyPath<State, Value> & Sendable, send: @escaping (Value) -> Action
  ) -> Binding<Value>
}

extension View {
  /// Store を Environment に入れる。子では @Environment(Store<AppState, AppAction>.self) で取り出す。
  public func store<State, Action>(_ store: Store<State, Action>) -> some View
}
```

### UIKit（`ReduxUIKit`）

- iOS 26 以降（および `UIObservationTrackingEnabled` を有効にした iOS 18 以降）は、`viewWillLayoutSubviews()` / `layoutSubviews()` / `updateProperties()` などで `store.count` を読むだけで UIKit が自動で追跡する。ライブラリ側の追加作業はない（5.4 の追跡単位がそのまま効く）。
- それ以前の OS や、ライフサイクル外で購読したい場合は `store.observe(_:onChange:)`（5.9）を使う。
- ヘルパー:

```swift
extension ObservationToken {
  /// owner が解放されるまで購読を続ける（Associated Object で保持）。
  public func retained(by owner: AnyObject)
}

extension Store {
  /// 実行すると Action を dispatch する UIAction（Store は弱参照）。
  public func action(_ action: Action, title: String = "", image: UIImage? = nil) -> UIAction
}
```

- `retained(by:)` の Associated Object のキーにトークン自身のアドレスを使う。グローバルな可変のキーを持たないため。

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

`Examples/` の構成:

```
Examples/
├── ExampleKit/          ローカルパッケージ
│   ├── Domain           Todo / User と Repository / UseCase（本ライブラリに依存しない）
│   └── AppFeature       AuthFeature・TodoFeature（Slice と Saga）/ RootFeature（2 つを親に接続）/ AppStore（組み立て・永続化）/ TodoListViewModel（MVVM）
├── SwiftUIExample/      SwiftUI アプリ（Login・Settings: Store を直接使う、ToDo: MVVM 経由）
├── UIKitExample/        UIKit アプリ（同上。iOS 17 から動くよう observe を使う）
└── Examples.xcodeproj   両アプリ（default MainActor isolation を有効にしている）
```

- 画面ごとに、Store を直接使う書き方（設定画面: 画面特有の状態がない）と、MVVM を経由する書き方（ToDo の画面）を並べて示す。
- 機能（ログイン、ToDo）ごとに State・Action・Saga を分け、それぞれの型のまま親（`RootFeature`）に接続する（5.6 の `Reducer.slice`、6.9 の Saga の接続）。ToDo の Saga はログイン中だけ動かし、ログアウトでキャンセルする。
- Single source of truth を保つ。データは Store にだけ置き、ViewModel は Store を読む計算プロパティと、Store に送る操作だけを持つ（写しを持たない）。ViewModel が持つのは、Store にない画面特有の状態だけにする。View / ViewController も表示用の写しを持たず、必要なときに ViewModel（の先の Store）から読む。
- MVVM と併用する画面では、画面特有の状態（入力中の文字列など）は ViewModel（`@Observable`）に持たせ、複数の画面で使うデータと Saga が関わる処理、永続化する設定は Store に置く。ViewModel は Store を読む計算プロパティを公開し、Observation がそのまま連鎖する。View / ViewController は ViewModel だけを見る。UIKit では `ObservationToken.observe` で ViewModel を購読する。
- Xcode プロジェクトはフォルダ同期（`PBXFileSystemSynchronizedRootGroup`）を使い、ソースの追加でプロジェクトファイルを編集しなくて済むようにする。
- シミュレータや実機での動作確認には [callstack/agent-device](https://github.com/callstack/agent-device) を使う。

---

## 12. マクロ

`ReduxMacros` ターゲット（プロダクト）で提供します。マクロの実装（`ReduxMacrosPlugin`）だけが swift-syntax に依存します。マクロなしでも全機能が使えます。

### `@ActionCases`

enum の case ごとに、「その case なら関連値を返し、そうでなければ `nil` を返す」プロパティを生成します。

```swift
@ActionCases
enum AppAction: Sendable {
  case user(UserAction)          // var user: (UserAction)?
  case rename(first: String, last: String)   // var rename: (first: String, last: String)?
  case reset                     // var reset: Void?
}
```

生成されたプロパティのキーパスを、マクロに依存しない次の API に渡します。

```swift
extension ActionPattern {
  public static func `case`(_ keyPath: KeyPath<Action, Value?> & Sendable) -> Self
}
extension Reducer {
  public static func scope(state:action: KeyPath<Action, ChildAction?> & Sendable, reducer:) -> Reducer
  public static func slice(_:state:action: KeyPath<Action, S.Action?> & Sendable) -> Reducer
}

ctx.takeEvery(.case(\.user?.fetch)) { ctx, id in ... }        // ネストした enum もたどれる
Reducer.slice(Counter.self, state: \.counter, action: \.counter)
```

- ActionPattern の静的メンバー（`.user`）を生成しないのは、拡張マクロは付けた型にしか拡張を追加できず、`ActionPattern` を拡張できないため。プロパティを生成してキーパスで渡す形にした。
- キーパス版の API はマクロに依存しない。手書きのプロパティでも使える。

### `@Slice`

```swift
@Slice
enum Counter {
  struct State: Sendable, Equatable { var count = 0 }
  enum Action: Sendable { case increment }
  static func reduce(into state: inout State, action: Action) { ... }
}
```

- `Slice` への準拠を追加する（拡張マクロ）。
- `initialState` がなければ `static let initialState = State()` を追加する。
- 中の `enum Action` に `@ActionCases` を付ける。
- `State` / `Action` に `Sendable` を自動で付けない。拡張マクロは付けた型（`Counter`）にしか準拠を追加できず、中の型には付けられないため。
- default MainActor isolation のモジュールでは `@Slice nonisolated enum Counter` と書く。

### 利用時の注意

- Xcode は初めてパッケージのマクロを使うときに許可を求める。`xcodebuild` では `-skipMacroValidation` を付ける（CI で設定済み）。
- swift-syntax の版は `600.0.0..<605.0.0` の範囲で解決する。利用者の Xcode に同梱のビルド済み swift-syntax を選べるようにするため。

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

## 14. 決定事項

設計 PR（#1）の「要確認事項」で確認し、決まった内容です。

1. **ライセンス**: MIT。
2. **Swift ツールチェーンの下限**: Swift 6.2（Xcode 26）以降。
3. **OS の下限**: iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1。排他制御は Apple OS では `OSAllocatedUnfairLock`、Linux では `Mutex` を使う（`InternalPrimitives.Locked`）。
4. **Action の表現**: `Store<State, Action>` のジェネリクスで、enum とプロトコル存在型の両方を許す。Action 専用のプロトコルは設けない（5.1）。
5. **プロパティ単位の追跡**: 自前の `ObservationRegistrar` とキーパス比較で実現した（5.4）。ネストした値は `@TrackedState` で追跡する。
6. **`put` の意味**: reducer の適用完了まで待つ（`await`）。
7. **ターゲット分割**: Slice / Selector / EntityAdapter / LoggingMiddleware は `Redux` に含める。Foundation を使う永続化は `ReduxPersistence` に分ける。
8. **Example の形式**: `Examples/` にローカルパッケージ（Domain / AppFeature）と Xcode プロジェクト（SwiftUI / UIKit アプリ）を置く。MVVM と併用する。
9. **Linux CI**: UI に依存しないターゲットのビルドとテストを Linux（公式 `swift` コンテナイメージ）でも行う。

設計書の当初の案から変えた点（理由は各章）:

- dispatch 中の dispatch は禁止せず、キューに積んで後で処理する（5.3）。
- 起動直後の Action は、Saga が最初の Effect に達するまで溜めて後から届ける（7 章）。
- `all` / `race` の処理は `(SagaContext) async throws -> R` を受け取る（6.5）。
- マクロで Action を取り出す書き方は `.case(\.toggleTapped)`（12 章）。
- 入力欄の Binding はマクロではなくプロパティラッパー（`@BindableState`）にした（5.10）。
