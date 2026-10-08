/// Saga の本体。
///
/// Saga は ``SagaContext`` を受け取る async 関数です。redux-saga のジェネレーター関数の `yield` の代わりに、
/// コンテキストの Effect を `await` で呼びます。
///
/// ```swift
/// struct UserSagas: Sendable {
///   let fetchUser: FetchUserUseCase
///
///   var root: Saga<AppState, AppAction> {
///     Saga("user") { ctx in
///       while true {
///         let id = try await ctx.take(.case { if case .user(.fetch(let id)) = $0 { id } else { nil } })
///         let user = try await ctx.call(fetchUser.execute, id)
///         await ctx.put(.user(.fetched(user)))
///       }
///     }
///   }
/// }
/// ```
public struct Saga<State: Sendable, Action: Sendable>: Sendable {
  /// デバッグ用の名前。エラーの経路（``SagaError/sagaStack``）などに使われます。
  public let name: String?
  private let body: @Sendable (SagaContext<State, Action>) async throws -> Void

  /// Saga を作ります。
  ///
  /// - Parameters:
  ///   - name: デバッグ用の名前。
  ///   - body: Saga の本体。
  public init(
    _ name: String? = nil,
    _ body: @escaping @Sendable (SagaContext<State, Action>) async throws -> Void
  ) {
    self.name = name
    self.body = body
  }

  /// 本体を、渡したコンテキストの中でそのまま実行します。
  ///
  /// ほかの Saga の中から、子として fork せずに呼び出す場合に使います（redux-saga の `yield* saga()` 相当）。
  public func run(_ context: SagaContext<State, Action>) async throws {
    try await body(context)
  }

  /// 複数の Saga を並行に実行する Saga を作ります。
  ///
  /// 各 Saga は fork され、すべてが終わると完了します。いずれかが失敗すると、残りはキャンセルされます。
  public static func combine(_ sagas: Saga..., name: String? = nil) -> Saga {
    Saga(name) { context in
      for saga in sagas {
        context.fork(saga)
      }
    }
  }
}
