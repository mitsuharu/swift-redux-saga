/// dispatch された Action が reducer に届くまでの間に処理を挟む仕組み。
///
/// ミドルウェアは Store に渡した順に呼ばれ、`next` を呼ぶと次のミドルウェア（最後は reducer）に進みます。
/// `next` を呼ばなければ、その Action は reducer に届きません。
///
/// ```swift
/// struct LoggerMiddleware<State: Sendable, Action: Sendable>: Middleware {
///   func handle(_ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void) {
///     print("action:", action)
///     next(action)
///     print("state:", store.state)
///   }
/// }
/// ```
@MainActor
public protocol Middleware<State, Action> {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Store の生成時に 1 回呼ばれます。
  ///
  /// `store` を保持して、後から State を読んだり Action を dispatch したりできます。
  func attach(to store: MiddlewareAPI<State, Action>)

  /// Action ごとに呼ばれます。
  ///
  /// - Parameters:
  ///   - action: dispatch された Action。
  ///   - store: Store の窓口。
  ///   - next: 次のミドルウェア（最後は reducer）に Action を渡す関数。
  func handle(_ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void)
}

extension Middleware {
  public func attach(to store: MiddlewareAPI<State, Action>) {}
}

/// ミドルウェアに渡す Store の窓口。
///
/// Store を弱参照で持ちます。ミドルウェアが窓口を保持しても、Store との循環参照になりません。
@MainActor
public struct MiddlewareAPI<State: Sendable, Action: Sendable>: Sendable {
  private weak var store: Store<State, Action>?

  init(store: Store<State, Action>) {
    self.store = store
  }

  /// Store がまだ存在するかどうか。
  public var isStoreAlive: Bool {
    store != nil
  }

  /// 現在の State。
  ///
  /// Observation の追跡対象にはなりません。
  /// Store が解放された後に読むとプログラムを停止します（先に ``isStoreAlive`` で確認してください）。
  public var state: State {
    guard let store else {
      preconditionFailure("The store has been deallocated.")
    }
    return store.untrackedState
  }

  /// Store に Action を dispatch します。
  ///
  /// ミドルウェアの `handle` の中から呼んだ場合は、処理中の Action が終わった後に処理されます。
  /// Store が解放された後は何もしません。
  public func dispatch(_ action: Action) {
    store?.dispatch(action)
  }
}
