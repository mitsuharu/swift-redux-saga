import InternalPrimitives
import Redux
import Saga

/// Redux の Store に Saga を載せるミドルウェア。
///
/// ```swift
/// let sagaMiddleware = SagaMiddleware<AppState, AppAction>()
/// let store = Store(initialState: AppState(), reducer: appReducer, middleware: [sagaMiddleware])
/// sagaMiddleware.run(appSagas.root)
/// ```
///
/// Saga が受け取るのは、reducer を適用した後の Action です（redux-saga と同じ）。
/// Store が解放されると、ミドルウェアも解放され、動いている Saga はすべてキャンセルされます。
@MainActor
public final class SagaMiddleware<State: Sendable, Action: Sendable>: Middleware {
  private let host: StoreHost<State, Action>
  private let runtime: SagaRuntime<State, Action>

  /// ミドルウェアを作ります。
  ///
  /// - Parameters:
  ///   - clock: `delay` などが使う時計。
  ///   - monitor: Saga の起動・終了・Effect を受け取るフック。
  ///   - onError: 根まで伝わった未処理のエラーを受け取る関数。既定ではログに出力します。
  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    monitor: (any SagaMonitor)? = nil,
    onError: @escaping @Sendable (SagaError) -> Void = SagaRuntime<State, Action>.logError
  ) {
    let host = StoreHost<State, Action>()
    self.host = host
    self.runtime = SagaRuntime(host: host, clock: clock, monitor: monitor, onError: onError)
  }

  // Store の解放でミドルウェアが解放されたら、Saga を止める。
  // runtime は Sendable な let なので、隔離されていない deinit から触れる。
  deinit {
    runtime.stop()
  }

  /// Saga を起動します。Store を作った後に呼んでください。
  ///
  /// - Returns: 起動した Saga のハンドル。
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask {
    precondition(host.isAttached, "Create the Store with this middleware before calling run(_:).")
    return runtime.run(saga)
  }

  /// すべての Saga が Effect（`take` / `join` / `delay` など）で止まるまで待ちます。
  ///
  /// Saga は ``run(_:)`` から非同期に動き出すため、起動直後に dispatch した Action は、まだ `take` で
  /// 待ち始めていない Saga には届きません。起動直後の Action を確実に届けたい場合は、先にこのメソッドで待つか、
  /// その処理（起動時の読み込みなど）をルート Saga の中に書いてください。
  ///
  /// `call` で呼んだ関数が終わらない場合は、このメソッドも戻りません。
  public func waitUntilIdle() async {
    await runtime.waitUntilIdle()
  }

  /// 動いている Saga をすべてキャンセルします。以降に ``run(_:)`` した Saga もすぐにキャンセルされます。
  public func stop() {
    runtime.stop()
  }

  public func attach(to store: MiddlewareAPI<State, Action>) {
    host.attach(store)
  }

  public func handle(
    _ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void
  ) {
    next(action)
    host.remember(store.state)
    runtime.emit(action)
  }
}

/// Saga から見た Store の窓口。
final class StoreHost<State: Sendable, Action: Sendable>: SagaHost {
  private struct Storage {
    var api: MiddlewareAPI<State, Action>?
    var lastState: State?
  }

  private let storage = Locked(Storage())

  var isAttached: Bool {
    storage.withLock { $0.api != nil }
  }

  @MainActor
  func attach(_ api: MiddlewareAPI<State, Action>) {
    let state = api.state
    storage.withLock {
      $0.api = api
      $0.lastState = state
    }
  }

  /// Store が解放された後も `state()` に答えられるよう、最後の State を覚えておく。
  func remember(_ state: State) {
    storage.withLock { $0.lastState = state }
  }

  func dispatch(_ action: Action) async {
    guard let api = storage.withLock({ $0.api }) else { return }
    // Store の dispatch は同期で、戻った時点で reducer の適用が終わっている。
    await MainActor.run {
      api.dispatch(action)
    }
  }

  func state() async -> State {
    guard let api = storage.withLock({ $0.api }) else {
      preconditionFailure("The saga middleware is not attached to a store.")
    }
    let current = await MainActor.run { api.isStoreAlive ? api.state : nil }
    if let current { return current }
    guard let lastState = storage.withLock({ $0.lastState }) else {
      preconditionFailure("The saga middleware is not attached to a store.")
    }
    return lastState
  }
}
