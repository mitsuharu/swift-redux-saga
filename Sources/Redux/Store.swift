import InternalPrimitives
import Observation

/// アプリの State を保持し、Action を reducer に通して更新するコンテナ。
///
/// `Store` は `@MainActor` で隔離され、`Observable` に準拠します。SwiftUI の View や
/// `withObservationTracking` から State を読むと、その変化が追跡されます。
///
/// `store.counter.count` のように State のプロパティを直接読むと、そのプロパティが変わったときだけ
/// 通知されます。`store.state.counter.count` のように `state` を経由すると、State のどこが変わっても通知されます。
///
/// ```swift
/// let store = Store(initialState: AppState(), reducer: appReducer)
/// store.dispatch(.counter(.increment))
/// print(store.counter.count)
/// ```
@MainActor
@dynamicMemberLookup
public final class Store<State: Sendable, Action: Sendable>: Observable {
  private var currentState: State
  private let reducer: Reducer<State, Action>
  private let middleware: [any Middleware<State, Action>]
  // `@Observable` マクロを使わないのは、5.4 のキーパス単位の通知を自前で行うため。
  private let registrar = ObservationRegistrar()
  // 読まれたキーパスごとの、新旧の State で値が変わったかを判定する関数。キーは State 上のキーパス。
  // 値が変わって通知したキーパスは外す（Observation の購読は 1 回通知されると外れ、読み直したときに
  // 登録し直されるため）。外さないと、`\.items[id: id]` のように値ごとに異なるキーパスが溜まり続ける。
  // 値が変わらないまま読まれなくなったキーパスは、一定の間隔で外す（`sweepUnreadKeyPaths()`）。
  private var trackedKeyPaths: [AnyKeyPath: TrackedKeyPath] = [:]
  // 読まれなくなったキーパスを外す処理の回数と、前回からの更新の回数。
  private var sweepCount = 0
  private var updatesSinceSweep = 0
  // TrackedState の中で読まれたキーパス（State から）ごとの、値が変わったかを判定する関数。
  // 読み取りは TrackedState の値のコピーから行われ、メインアクター外で起き得るため、ロックで守る。
  private let nestedKeyPaths = Locked<[SendableKeyPath: @Sendable (State, State) -> Bool]>([:])
  private var pendingActions: [Action] = []
  private var isDispatching = false
  // scope で作った Store では、Action を親の Store に送る関数。親を強参照するので、子がある間は親も残る。
  private let forward: ((Action) -> Void)?
  // scope で作った子の Store に、State の変化を伝える関数。子が解放されていたら false を返す。
  private var children: [Int: (State) -> Bool] = [:]
  private var nextChildID = 0

  /// Store を作ります。
  ///
  /// - Parameters:
  ///   - initialState: State の初期値。
  ///   - reducer: Action を State に適用する reducer。
  ///   - middleware: Action が reducer に届くまでに通すミドルウェア。配列の順に呼ばれます。
  public init(
    initialState: State,
    reducer: Reducer<State, Action>,
    middleware: [any Middleware<State, Action>] = []
  ) {
    self.currentState = initialState
    self.reducer = reducer
    self.middleware = middleware
    self.forward = nil
    let api = MiddlewareAPI(store: self)
    for middleware in middleware {
      middleware.attach(to: api)
    }
  }

  /// 現在の State。
  ///
  /// Observation の追跡中に読むと、State 全体の変化が追跡対象になります。
  public var state: State {
    registrar.access(self, keyPath: \.state)
    return currentState
  }

  /// State のプロパティを読みます。
  ///
  /// Observation の追跡中に読むと、このプロパティの値が変わったときだけ通知されます。
  public subscript<Value: Equatable>(
    dynamicMember keyPath: KeyPath<State, Value> & Sendable
  ) -> Value {
    trackedKeyPath(for: keyPath).access(self)
    return currentState[keyPath: keyPath]
  }

  /// State のプロパティ（``TrackedState`` の値）を読みます。
  ///
  /// 返した値のプロパティを読むと、そのプロパティが変わったときだけ通知されます。
  public subscript<Value: TrackedState>(
    dynamicMember keyPath: KeyPath<State, Value> & Sendable
  ) -> Value {
    if Value._$hasUntrackedProperties {
      // 追跡できないプロパティがあり、値が Equatable でないので、State 全体の変化で通知する。
      registrar.access(self, keyPath: \.state)
    }
    return trackedValue(at: keyPath)
  }

  /// State のプロパティ（``TrackedState`` で `Equatable` な値）を読みます。
  ///
  /// 返した値のプロパティを読むと、そのプロパティが変わったときだけ通知されます。
  public subscript<Value: TrackedState & Equatable>(
    dynamicMember keyPath: KeyPath<State, Value> & Sendable
  ) -> Value {
    if Value._$hasUntrackedProperties {
      // 追跡できないプロパティがあるので、値全体の変化でも通知する。
      trackedKeyPath(for: keyPath).access(self)
    }
    return trackedValue(at: keyPath)
  }

  /// State のプロパティを読みます。
  ///
  /// 値が `Equatable` でないため変化を判定できず、State 全体の変化が追跡対象になります。
  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value> & Sendable) -> Value {
    registrar.access(self, keyPath: \.state)
    return currentState[keyPath: keyPath]
  }

  /// State と Action の一部だけを扱う Store を作ります（機能ごとの画面に渡すため）。
  ///
  /// 作った Store は State を持たず、この Store の State から `state` で取り出した値を読みます。
  /// dispatch した Action は `action` で包んで、この Store に送ります。機能ごとのモジュールの View や
  /// ViewModel が、アプリ全体の `AppState` / `AppAction` を知らずに、機能の型の Store だけで書けます
  /// （Reducer の `scope`、Saga の `run(_:state:action:embed:)` と同じ考え方）。
  ///
  /// ```swift
  /// let todoStore = store.scope(state: \.todo, action: AppAction.todo)
  /// TodoListView(store: todoStore)   // Store<TodoFeature.State, TodoFeature.Action>
  /// ```
  ///
  /// 読み取りの追跡は、作った Store でもプロパティ単位です。呼ぶたびに新しい Store を作るので、
  /// View の `body` の中で毎回呼ぶより、ViewModel や親の View で作って渡してください。
  ///
  /// - Parameters:
  ///   - state: この Store の State から、子の State を取り出す関数。
  ///   - action: 子の Action を、この Store の Action に包む関数（enum の case など）。
  /// - Returns: 子の State と Action を扱う Store。
  public func scope<ChildState: Sendable, ChildAction: Sendable>(
    state toChildState: @escaping (State) -> ChildState,
    action embed: @escaping (ChildAction) -> Action
  ) -> Store<ChildState, ChildAction> {
    let child = Store<ChildState, ChildAction>(
      scopedState: toChildState(currentState),
      forward: { self.dispatch(embed($0)) })
    defer { nextChildID += 1 }
    children[nextChildID] = { [weak child] newState in
      guard let child else { return false }
      child.update(to: toChildState(newState))
      return true
    }
    return child
  }

  /// State と Action の一部だけを扱う Store を作ります（State をキーパスで取り出す版）。
  public func scope<ChildState: Sendable, ChildAction: Sendable>(
    state: KeyPath<State, ChildState>,
    action embed: @escaping (ChildAction) -> Action
  ) -> Store<ChildState, ChildAction> {
    scope(state: { $0[keyPath: state] }, action: embed)
  }

  /// scope で作る Store。State を持たず、親から変化を知らされる。
  private init(scopedState: State, forward: @escaping (Action) -> Void) {
    self.currentState = scopedState
    self.reducer = .empty
    self.middleware = []
    self.forward = forward
  }

  /// Observation の追跡に登録せずに State を読む（ミドルウェアと、SwiftUI の `SelectState` 用）。
  package var untrackedState: State {
    currentState
  }

  /// Action をミドルウェアと reducer に通し、State を更新します。
  ///
  /// 処理は同期で、戻った時点で State は更新済みです。
  /// dispatch の処理中（Observation の通知の中など）に呼ばれた Action は、
  /// 処理中の Action が終わった後に、呼ばれた順に処理します。
  public func dispatch(_ action: Action) {
    if let forward {
      forward(action)
      return
    }
    pendingActions.append(action)
    // 再入時にその場で処理しないのは、通知の途中で State が書き換わり、
    // 先に呼ばれた Action より後の Action の結果が先に見えてしまうため。
    guard !isDispatching else { return }
    isDispatching = true
    defer { isDispatching = false }
    while !pendingActions.isEmpty {
      run(pendingActions.removeFirst(), throughMiddlewareAt: 0)
    }
  }

  private func run(_ action: Action, throughMiddlewareAt index: Int) {
    guard index < middleware.count else {
      apply(action)
      return
    }
    middleware[index].handle(action, store: MiddlewareAPI(store: self)) { action in
      run(action, throughMiddlewareAt: index + 1)
    }
  }

  private func apply(_ action: Action) {
    var newState = currentState
    reducer.reduce(into: &newState, action: action)
    update(to: newState)
  }

  /// State を新しい値にし、変わったキーパスを読んでいる側と、scope で作った子の Store に知らせる。
  private func update(to newState: State) {
    let oldState = currentState
    // State が Equatable で変わっていなければ、どのキーパスの値も変わっていないので比べない。
    guard !isEqualIfEquatable(oldState, newState) else {
      currentState = newState
      return
    }
    let changedEntries = trackedKeyPaths.filter { $0.value.hasChanged(oldState, newState) }
    let changed = Array(changedEntries.values)
    let changedNestedPaths = nestedKeyPaths.withLock { $0 }
      .filter { $0.value(oldState, newState) }
      .map(\.key)
    let nestedChanged = changedNestedPaths.map { \Store[trackedPath: $0] }
    // 通知する前に外す。通知を受けた側が読み直したら、その読み取りで登録し直される。
    for key in changedEntries.keys { trackedKeyPaths[key] = nil }
    nestedKeyPaths.withLock { entries in
      for path in changedNestedPaths { entries[path] = nil }
    }

    // withMutation を使わないのは、変わったキーパスが複数あり、
    // 全部の willSet → 代入 → 全部の didSet の順にしないと、通知を受けた側が途中の State を見るため。
    registrar.willSet(self, keyPath: \.state)
    for tracked in changed { tracked.willSet(self) }
    for keyPath in nestedChanged { registrar.willSet(self, keyPath: keyPath) }
    currentState = newState
    registrar.didSet(self, keyPath: \.state)
    for tracked in changed { tracked.didSet(self) }
    for keyPath in nestedChanged { registrar.didSet(self, keyPath: keyPath) }
    notifyChildren(of: newState)
    sweepUnreadKeyPathsIfNeeded()
  }

  /// 前回の掃除から一度も読まれていないキーパスを、通知してから追跡の表から外す。
  ///
  /// 値が変わらないキーパス（削除済みの要素を読んだ `nil` など）は、変化の通知で外れないため溜まり続ける。
  /// 購読がまだ残っているかは Observation から分からないので、外すときに通知する。まだ読んでいる側は
  /// 読み直し、その読み取りで登録し直される。読んでいない側の購読は、この通知で消える。
  /// 間隔を表の大きさに比例させるのは、掃除の手間と、読み直しの回数を、更新 1 回あたりで一定に抑えるため。
  private func sweepUnreadKeyPathsIfNeeded() {
    updatesSinceSweep += 1
    guard updatesSinceSweep >= max(256, trackedKeyPaths.count) else { return }
    updatesSinceSweep = 0
    let unread = trackedKeyPaths.filter { $0.value.lastSweepRead < sweepCount }
    sweepCount += 1
    guard !unread.isEmpty else { return }
    for key in unread.keys { trackedKeyPaths[key] = nil }
    for tracked in unread.values { tracked.willSet(self) }
    for tracked in unread.values { tracked.didSet(self) }
  }

  /// scope で作った子の Store に、新しい State を知らせる。
  private func notifyChildren(of newState: State) {
    // 写しを回すのは、知らせた先（Observation の通知）で scope が呼ばれ、children に追加されても
    // 回している最中の配列を書き換えないため（書き換えると排他アクセス違反で停止する）。
    let current = children
    var released: [Int] = []
    for (id, notify) in current where !notify(newState) {
      released.append(id)
    }
    for id in released { children[id] = nil }
  }

  private func trackedKeyPath<Value: Equatable>(
    for keyPath: KeyPath<State, Value> & Sendable
  ) -> TrackedKeyPath {
    if let tracked = trackedKeyPaths[keyPath] {
      if tracked.lastSweepRead != sweepCount {
        trackedKeyPaths[keyPath]?.lastSweepRead = sweepCount
      }
      return tracked
    }
    // ObservationRegistrar は通知の単位を Store 上のキーパスで区別するため、
    // `\Store.state` に State 上のキーパスをつないだものを使う。
    let storeKeyPath = (\Store.state).appending(path: keyPath)
    let tracked = TrackedKeyPath(
      hasChanged: { $0[keyPath: keyPath] != $1[keyPath: keyPath] },
      access: { $0.registrar.access($0, keyPath: storeKeyPath) },
      willSet: { $0.registrar.willSet($0, keyPath: storeKeyPath) },
      didSet: { $0.registrar.didSet($0, keyPath: storeKeyPath) },
      lastSweepRead: sweepCount
    )
    trackedKeyPaths[keyPath] = tracked
    return tracked
  }

  /// TrackedState の値に、読み取りを Store に知らせる先を付けて返す。
  private func trackedValue<Value: TrackedState>(at keyPath: KeyPath<State, Value> & Sendable)
    -> Value
  {
    var value = currentState[keyPath: keyPath]
    let registrar = registrar
    let nestedKeyPaths = nestedKeyPaths
    value._$tracking = StateTrackingContext(base: SendableKeyPath(keyPath)) {
      [weak self] path in
      guard let self else { return }
      nestedKeyPaths.withLock { entries in
        if entries[path] == nil {
          entries[path] = {
            isEqualIfEquatable($0[keyPath: path.keyPath], $1[keyPath: path.keyPath]) == false
          }
        }
      }
      // ObservationRegistrar は通知の単位を Store 上のキーパスで区別するため、
      // State 上のキーパスを添字に持つキーパス（\Store[trackedPath:]）を使う。
      registrar.access(self, keyPath: \Store[trackedPath: path])
    }
    return value
  }

  /// ネストしたキーパスの通知に使う、値を持たない添字。
  nonisolated subscript(trackedPath path: SendableKeyPath) -> Int {
    0
  }

  // キーパスの値の型（Value）を消して 1 つの辞書に入れるため、型ごとの処理をクロージャに閉じ込める。
  private struct TrackedKeyPath {
    let hasChanged: (State, State) -> Bool
    let access: (Store) -> Void
    let willSet: (Store) -> Void
    let didSet: (Store) -> Void
    /// 最後に読まれたときの掃除の回数（`sweepCount`）。
    var lastSweepRead: Int
  }
}
