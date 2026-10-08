/// Saga の中で Effect を呼ぶためのコンテキスト。
///
/// Saga の本体に渡されます。Effect はすべてこの型のメソッドです（トップレベル関数にしないのは、
/// どのランタイムに対する Effect かを型で決め、`take` などの一般的な名前の衝突を避けるため）。
public struct SagaContext<State: Sendable, Action: Sendable>: Sendable {
  let runtime: SagaRuntime<State, Action>
  let forks: ForkQueue<SagaRuntime<State, Action>.ForkRequest>

  /// 現在のタスクがキャンセルされているかどうか（redux-saga の `cancelled()` 相当）。
  public var isCancelled: Bool {
    Task.isCancelled
  }

  // MARK: - take

  /// 次に届く、パターンに一致する Action を待ち、取り出した値を返します。
  ///
  /// 待ち始める前に届いた Action は受け取りません。取りこぼしたくない場合は `actionChannel` を使います。
  ///
  /// - Throws: 待っている間にキャンセルされた場合は `CancellationError`。
  public func take<Value>(_ pattern: ActionPattern<Action, Value>) async throws -> Value {
    try await runtime.multicaster.take(pattern)
  }

  /// 次に届く Action を待ちます。
  public func take() async throws -> Action {
    try await take(.any)
  }

  // MARK: - put

  /// Action を発行します。Host が Action を処理し終えてから戻ります。
  public func put(_ action: Action) async {
    await runtime.host.dispatch(action)
  }

  // MARK: - select

  /// 現在の State を返します。
  public func select() async -> State {
    await runtime.host.state()
  }

  /// 現在の State から値を取り出します。
  public func select<Value>(_ selector: (State) -> Value) async -> Value {
    selector(await runtime.host.state())
  }

  // MARK: - join

  /// Saga が終わるまで待ちます。
  ///
  /// - Throws: 待っている Saga が失敗した場合はそのエラー、キャンセルされた場合は `CancellationError`。
  ///   待っている側がキャンセルされた場合も `CancellationError` を投げます（待たれている Saga は止まりません）。
  public func join(_ task: SagaTask) async throws {
    try await task.state.join(fromSaga: true)
  }

  // MARK: - call

  /// 任意の async 関数を呼びます。
  ///
  /// `try await function(arguments...)` と直接書くのと同じ結果ですが、呼ぶ前にキャンセルを確認します。
  ///
  /// ```swift
  /// let user = try await ctx.call(fetchUser.execute, id)
  /// ```
  ///
  /// - Throws: 呼ぶ前にキャンセルされていれば `CancellationError`。関数が投げたエラーはそのまま投げます。
  public func call<each Argument, Result>(
    _ function: (repeat each Argument) async throws -> Result,
    _ arguments: repeat each Argument
  ) async throws -> Result {
    try Task.checkCancellation()
    return try await function(repeat each arguments)
  }
}
