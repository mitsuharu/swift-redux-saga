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
  private var pendingActions: [Action] = []
  private var isDispatching = false

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

  /// State のプロパティを読みます。
  ///
  /// 値が `Equatable` でないため変化を判定できず、State 全体の変化が追跡対象になります。
  public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value> & Sendable) -> Value {
    registrar.access(self, keyPath: \.state)
    return currentState[keyPath: keyPath]
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
    let oldState = currentState
    var newState = oldState
    reducer.reduce(into: &newState, action: action)

    let stateChanged = !isEqualIfEquatable(oldState, newState)
    let changed = trackedKeyPaths.values.filter { $0.hasChanged(oldState, newState) }

    // withMutation を使わないのは、変わったキーパスが複数あり、
    // 全部の willSet → 代入 → 全部の didSet の順にしないと、通知を受けた側が途中の State を見るため。
    if stateChanged { registrar.willSet(self, keyPath: \.state) }
    for tracked in changed { tracked.willSet(self) }
    currentState = newState
    if stateChanged { registrar.didSet(self, keyPath: \.state) }
    for tracked in changed { tracked.didSet(self) }
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
