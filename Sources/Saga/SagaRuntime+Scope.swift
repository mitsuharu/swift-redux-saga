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
  /// 子の Saga はこのランタイムの ``stop()`` で止まり、``waitUntilIdle()`` の対象になります。未処理のエラーは
  /// このランタイムの `onError` に渡します。
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
    let child = SagaRuntime<ChildState, ChildAction>(
      host: ScopedHost(parent: host, state: state, embed: embed),
      clock: clock, monitor: monitor, onError: onError, activity: activity, nextID: nextIDSource)
    let id = makeScopeID()
    scopes.withLock {
      $0[id] = ScopedRuntime(
        emit: { parentAction in
          if let childAction = action(parentAction) { child.emit(childAction) }
        },
        stop: { child.stop() })
    }
    // 子の Saga が終わったら、Action を届けるのをやめて、子のランタイムを手放す。
    let task = child.run(saga)
    if task.state.addObserver({ [scopes] in _ = scopes.withLock { $0.removeValue(forKey: id) } })
      == nil
    {
      _ = scopes.withLock { $0.removeValue(forKey: id) }
    }
    // 接続する前に止められていた場合も、子を止める。
    if isStopped { child.stop() }
    return task
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

/// 子のランタイムから見た Host。親の Host を通して、子の State を読み、子の Action を親の Action にして発行する。
struct ScopedHost<ParentState: Sendable, ParentAction: Sendable, State: Sendable, Action: Sendable>:
  SagaHost
{
  let parent: any SagaHost<ParentState, ParentAction>
  let toChildState: @Sendable (ParentState) -> State
  let embed: @Sendable (Action) -> ParentAction

  init(
    parent: any SagaHost<ParentState, ParentAction>,
    state: @escaping @Sendable (ParentState) -> State,
    embed: @escaping @Sendable (Action) -> ParentAction
  ) {
    self.parent = parent
    self.toChildState = state
    self.embed = embed
  }

  func dispatch(_ action: Action) async {
    await parent.dispatch(embed(action))
  }

  func state() async -> State {
    toChildState(await parent.state())
  }
}

extension SagaContext {
  /// 子の State・Action で書いた Saga を、親の State・Action に接続して、子として起動します。
  ///
  /// ``SagaRuntime/run(_:state:action:embed:)`` と同じく子の型のまま動かし、``fork(_:)`` と同じく
  /// 呼び出し元がキャンセルされると止まります。ログイン中だけ動かす Saga を、ログアウトで止める場合などに使います。
  /// 子の Saga の未処理のエラーは `onError` に渡し、呼び出し元には伝えません。
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
    fork(saga.name ?? "scope") { ctx in
      let child = ctx.runtime.run(saga, state: state, action: action, embed: embed)
      try await withTaskCancellationHandler {
        do {
          try await ctx.join(child)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // 子の根で onError に渡し済み。fork の仕組みで親に伝えると、二重に報告されるため伝えない。
        }
      } onCancel: {
        child.cancel()
      }
    }
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
