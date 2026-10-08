import InternalPrimitives
import Saga

/// テスト用の Host。reducer で State を更新し、発行された Action を記録して、ランタイムに emit する。
final class TestHost<State: Sendable, Action: Sendable>: SagaHost {
  private struct Storage {
    var state: State
    var dispatched: [Action] = []
    var runtime: SagaRuntime<State, Action>?
  }

  private let storage: Locked<Storage>
  private let reducer: @Sendable (inout State, Action) -> Void

  init(initialState: State, reducer: @escaping @Sendable (inout State, Action) -> Void) {
    storage = Locked(Storage(state: initialState))
    self.reducer = reducer
  }

  /// この Host を使うランタイムを作る。
  func makeRuntime() -> SagaRuntime<State, Action> {
    let runtime = SagaRuntime(host: self)
    storage.withLock { $0.runtime = runtime }
    return runtime
  }

  var dispatched: [Action] {
    storage.withLock { $0.dispatched }
  }

  var currentState: State {
    storage.withLock { $0.state }
  }

  func dispatch(_ action: Action) async {
    let runtime = storage.withLock { [reducer] storage in
      reducer(&storage.state, action)
      storage.dispatched.append(action)
      return storage.runtime
    }
    runtime?.emit(action)
  }

  func state() async -> State {
    currentState
  }
}
