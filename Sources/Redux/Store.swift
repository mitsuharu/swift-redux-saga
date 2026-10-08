import Observation

/// アプリの State を保持し、Action を reducer に通して更新するコンテナ。
///
/// `Store` は `@MainActor` で隔離され、`Observable` に準拠します。SwiftUI の View や
/// `withObservationTracking` から `state` を読むと、その変化が追跡されます。
///
/// ```swift
/// let store = Store(initialState: AppState(), reducer: appReducer)
/// store.dispatch(.counter(.increment))
/// print(store.state.counter.count)
/// ```
@MainActor
public final class Store<State: Sendable, Action: Sendable>: Observable {
  private var currentState: State
  private let reducer: Reducer<State, Action>
  // `@Observable` マクロを使わないのは、5.4 のキーパス単位の通知を自前で行うため。
  private let registrar = ObservationRegistrar()
  private var pendingActions: [Action] = []
  private var isDispatching = false

  /// Store を作ります。
  ///
  /// - Parameters:
  ///   - initialState: State の初期値。
  ///   - reducer: Action を State に適用する reducer。
  public init(initialState: State, reducer: Reducer<State, Action>) {
    self.currentState = initialState
    self.reducer = reducer
  }

  /// 現在の State。
  ///
  /// Observation の追跡中に読むと、State 全体の変化が追跡対象になります。
  public var state: State {
    registrar.access(self, keyPath: \.state)
    return currentState
  }

  /// Action を reducer に適用し、State を更新します。
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
      apply(pendingActions.removeFirst())
    }
  }

  private func apply(_ action: Action) {
    var newState = currentState
    reducer.reduce(into: &newState, action: action)
    registrar.withMutation(of: self, keyPath: \.state) {
      currentState = newState
    }
  }
}
