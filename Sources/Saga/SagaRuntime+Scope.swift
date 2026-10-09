extension SagaRuntime {
  /// 子の State・Action で書いた Saga を、このランタイムの State・Action に接続して起動します。
  ///
  /// 機能ごとに分けたモジュール（`Todo` や `Auth`）の Saga を、子の型のまま親（`AppState` / `AppAction`）で動かせます。
  /// Reducer の `scope(state:action:reducer:)` と同じ考え方です。
  ///
  /// - 子の Saga の `select` は、親の State から `state` で取り出した子の State を返します。
  /// - 子の Saga の `take` には、親に届いた Action のうち `action` で取り出せたものが届きます。
  /// - 子の Saga の `put` は、`embed` で親の Action に包んで発行します。
  ///
  /// 子の Saga は、このランタイムの ``run(_:)`` で起動した Saga と同じに扱います。子が `spawn` した Saga も含めて
  /// ``stop()`` で止まり、``waitUntilIdle()`` の対象になり、未処理のエラーは `onError` に渡します。
  ///
  /// ```swift
  /// runtime.run(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)
  /// ```
  ///
  /// - Parameters:
  ///   - saga: 子の Saga。
  ///   - state: 親の State から子の State を取り出す関数。
  ///   - action: 親の Action から子の Action を取り出す関数。子の Action でなければ `nil` を返します。
  ///   - embed: 子の Action を親の Action に包む関数（enum の case など）。
  /// - Returns: 起動した子の Saga のハンドル。キャンセルすると子の Saga が止まります。
  @discardableResult
  public func run<ChildState: Sendable, ChildAction: Sendable>(
    _ saga: Saga<ChildState, ChildAction>,
    state: @escaping @Sendable (State) -> ChildState,
    action: @escaping @Sendable (Action) -> ChildAction?,
    embed: @escaping @Sendable (ChildAction) -> Action
  ) -> SagaTask {
    run(saga, in: rootEnvironment.scoped(state: state, action: action, embed: embed))
  }

  /// 子の Saga を、キーパスで親の State・Action に接続して起動します。
  ///
  /// `action` には、`@ActionCases` が生成する case のプロパティ（`\.todo`）を渡せます。
  @discardableResult
  public func run<ChildState: Sendable, ChildAction: Sendable>(
    _ saga: Saga<ChildState, ChildAction>,
    state: KeyPath<State, ChildState> & Sendable,
    action: KeyPath<Action, ChildAction?> & Sendable,
    embed: @escaping @Sendable (ChildAction) -> Action
  ) -> SagaTask {
    run(
      saga, state: { $0[keyPath: state] }, action: { $0[keyPath: action] }, embed: embed)
  }
}

extension SagaContext {
  /// 子の State・Action で書いた Saga を、親の State・Action に接続して、子として起動します。
  ///
  /// `SagaRuntime.run(_:state:action:embed:)` と同じく子の型のまま動かします。型を付け替えるだけで、
  /// ほかは ``fork(_:)`` とまったく同じです（呼び出し元のキャンセルで止まり、子の失敗は呼び出し元に伝わり、
  /// 呼び出し元は子の後始末が終わるまで完了しません）。ログイン中だけ動かす Saga を、ログアウトで止める場合などに使います。
  ///
  /// ```swift
  /// let session = ctx.fork(todoSagas.root, state: \.todo, action: \.todo, embed: AppAction.todo)
  /// _ = try await ctx.take(.case(\.logoutTapped))
  /// ctx.cancel(session)
  /// ```
  ///
  /// - Returns: 子の Saga のハンドル。キャンセルすると子の Saga が止まります。
  @discardableResult
  public func fork<ChildState: Sendable, ChildAction: Sendable>(
    _ saga: Saga<ChildState, ChildAction>,
    state: @escaping @Sendable (State) -> ChildState,
    action: @escaping @Sendable (Action) -> ChildAction?,
    embed: @escaping @Sendable (ChildAction) -> Action
  ) -> SagaTask {
    fork(
      saga, in: environment.scoped(state: state, action: action, embed: embed),
      waitsForFirstEffect: true)
  }

  /// 子の Saga を、キーパスで親の State・Action に接続して、子として起動します。
  @discardableResult
  public func fork<ChildState: Sendable, ChildAction: Sendable>(
    _ saga: Saga<ChildState, ChildAction>,
    state: KeyPath<State, ChildState> & Sendable,
    action: KeyPath<Action, ChildAction?> & Sendable,
    embed: @escaping @Sendable (ChildAction) -> Action
  ) -> SagaTask {
    fork(saga, state: { $0[keyPath: state] }, action: { $0[keyPath: action] }, embed: embed)
  }
}
