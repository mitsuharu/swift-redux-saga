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
  // 読まれたキーパスごとの、新旧の State で値が変わったかを判定する関数。
  // キーは State 上のキーパス。要素数はコード中で使われるキーパスの種類数で頭打ちになるため、削除しない。
  private var trackedKeyPaths: [AnyKeyPath: TrackedKeyPath] = [:]
  // TrackedState の中で読まれたキーパス（State から）ごとの、値が変わったかを判定する関数。
  // 読み取りは TrackedState の値のコピーから行われ、メインアクター外で起き得るため、ロックで守る。
  private let nestedKeyPaths = Locked<[SendableKeyPath: @Sendable (State, State) -> Bool]>([:])
  private var pendingActions: [Action] = []
  private var isDispatching = false
  // scope で作った Store では、Action を親の Store に送る関数。親を強参照するので、子がある間は親も残る。
  private let forward: ((Action) -> Void)?
  // scope で作った子の Store に、State の変化を伝える関数。子が解放されていたら false を返す。
  private var children: [(State, State) -> Bool] = []

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
    children.append { [weak child] _, newState in
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

  /// Observation の追跡に登録せずに State を読む（ミドルウェア用）。
  var untrackedState: State {
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
    let stateChanged = !isEqualIfEquatable(oldState, newState)
    let changed = trackedKeyPaths.values.filter { $0.hasChanged(oldState, newState) }
    let nestedChanged = nestedKeyPaths.withLock { $0 }
      .filter { $0.value(oldState, newState) }
      .map { \Store[trackedPath: $0.key] }

    // withMutation を使わないのは、変わったキーパスが複数あり、
    // 全部の willSet → 代入 → 全部の didSet の順にしないと、通知を受けた側が途中の State を見るため。
    if stateChanged { registrar.willSet(self, keyPath: \.state) }
    for tracked in changed { tracked.willSet(self) }
    for keyPath in nestedChanged { registrar.willSet(self, keyPath: keyPath) }
    currentState = newState
    if stateChanged { registrar.didSet(self, keyPath: \.state) }
    for tracked in changed { tracked.didSet(self) }
    for keyPath in nestedChanged { registrar.didSet(self, keyPath: keyPath) }
    // State が変わらなければ、子の State（State から取り出した値）も変わらないので知らせない。
    if stateChanged, !children.isEmpty {
      children.removeAll { notify in !notify(oldState, newState) }
    }
  }

  private func trackedKeyPath<Value: Equatable>(
    for keyPath: KeyPath<State, Value> & Sendable
  ) -> TrackedKeyPath {
    if let tracked = trackedKeyPaths[keyPath] {
      return tracked
    }
    // ObservationRegistrar は通知の単位を Store 上のキーパスで区別するため、
    // `\Store.state` に State 上のキーパスをつないだものを使う。
    let storeKeyPath = (\Store.state).appending(path: keyPath)
    let tracked = TrackedKeyPath(
      hasChanged: { $0[keyPath: keyPath] != $1[keyPath: keyPath] },
      access: { $0.registrar.access($0, keyPath: storeKeyPath) },
      willSet: { $0.registrar.willSet($0, keyPath: storeKeyPath) },
      didSet: { $0.registrar.didSet($0, keyPath: storeKeyPath) }
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
  }
}

/// 値が `Equatable` なら等しいかを返し、そうでなければ `false`（変わったとみなす）を返す。
private func isEqualIfEquatable<Value>(_ lhs: Value, _ rhs: Value) -> Bool {
  guard let lhs = lhs as? any Equatable else { return false }
  return lhs.isEqual(to: rhs)
}

extension Equatable {
  fileprivate func isEqual(to other: Any) -> Bool {
    guard let other = other as? Self else { return false }
    return self == other
  }
}
