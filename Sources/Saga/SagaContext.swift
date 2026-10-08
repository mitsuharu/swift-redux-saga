/// Saga の中で Effect を呼ぶためのコンテキスト。
///
/// Saga の本体に渡されます。Effect はすべてこの型のメソッドです（トップレベル関数にしないのは、
/// どのランタイムに対する Effect かを型で決め、`take` などの一般的な名前の衝突を避けるため）。
public struct SagaContext<State: Sendable, Action: Sendable>: Sendable {
  let runtime: SagaRuntime<State, Action>
  let forks: ForkQueue<SagaRuntime<State, Action>.ForkRequest>
  let sagaID: SagaID

  /// この Saga の識別子。
  public var id: SagaID {
    sagaID
  }

  private func trigger(_ effect: SagaEffect) {
    runtime.monitor?.effectTriggered(sagaID, effect: effect)
  }

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
    trigger(.take)
    return try await runtime.multicaster.take(pattern)
  }

  /// 次に届く Action を待ちます。
  public func take() async throws -> Action {
    try await take(.any)
  }

  // MARK: - put

  /// Action を発行します。Host が Action を処理し終えてから戻ります。
  public func put(_ action: Action) async {
    trigger(.put(String(describing: action)))
    await runtime.host.dispatch(action)
  }

  // MARK: - select

  /// 現在の State を返します。
  public func select() async -> State {
    trigger(.select)
    return await runtime.host.state()
  }

  /// 現在の State から値を取り出します。
  public func select<Value>(_ selector: (State) -> Value) async -> Value {
    selector(await select())
  }

  // MARK: - fork / spawn / cancel

  /// Saga を子として起動します（redux-saga の `fork`、attached）。
  ///
  /// 呼び出し元は待たずに続きを実行します。子は呼び出し元の Saga のタスクの子タスクとして動くため、
  /// - 呼び出し元がキャンセルされると、子もキャンセルされます。
  /// - 子が失敗すると、兄弟と呼び出し元がキャンセルされ、エラーが呼び出し元に伝わります。
  /// - 呼び出し元の本体が終わっても、子がすべて終わるまで呼び出し元は完了しません。
  ///
  /// 子を ``SagaTask/cancel()`` でキャンセルしても、呼び出し元にエラーは伝わりません。
  @discardableResult
  public func fork(_ saga: Saga<State, Action>) -> SagaTask {
    let state = runtime.makeTaskState()
    trigger(.fork(state.id))
    runtime.monitor?.sagaStarted(state.id, name: saga.name, parent: sagaID)
    runtime.activity.begin()
    let accepted = forks.push(
      SagaRuntime.ForkRequest { [runtime] in try await runtime.runForked(saga, state: state) })
    if !accepted {
      // 呼び出し元の本体が終わった後に fork された（コンテキストを外に持ち出した）場合。
      runtime.activity.end()
      runtime.finish(state, .cancelled)
    }
    return SagaTask(state: state)
  }

  /// 関数を Saga として子に起動します。`fork(_:)` と同じです。
  @discardableResult
  public func fork(
    _ name: String? = nil,
    _ body: @escaping @Sendable (SagaContext) async throws -> Void
  ) -> SagaTask {
    fork(Saga(name, body))
  }

  /// Saga を呼び出し元から切り離して起動します（redux-saga の `spawn`、detached）。
  ///
  /// 呼び出し元のキャンセルや失敗の影響を受けず、子の失敗も呼び出し元に伝わりません。
  /// ランタイムの停止（``SagaRuntime/stop()``）ではキャンセルされます。
  @discardableResult
  public func spawn(_ saga: Saga<State, Action>) -> SagaTask {
    let task = runtime.run(saga)
    trigger(.spawn(task.id))
    return task
  }

  /// 関数を Saga として切り離して起動します。`spawn(_:)` と同じです。
  @discardableResult
  public func spawn(
    _ name: String? = nil,
    _ body: @escaping @Sendable (SagaContext) async throws -> Void
  ) -> SagaTask {
    spawn(Saga(name, body))
  }

  /// Saga をキャンセルします。``SagaTask/cancel()`` と同じです。
  public func cancel(_ task: SagaTask) {
    trigger(.cancel(task.id))
    task.cancel()
  }

  // MARK: - join

  /// Saga が終わるまで待ちます。
  ///
  /// - Throws: 待っている Saga が失敗した場合はそのエラー、キャンセルされた場合は `CancellationError`。
  ///   待っている側がキャンセルされた場合も `CancellationError` を投げます（待たれている Saga は止まりません）。
  public func join(_ task: SagaTask) async throws {
    trigger(.join(task.id))
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
    trigger(.call)
    try Task.checkCancellation()
    return try await function(repeat each arguments)
  }
}
