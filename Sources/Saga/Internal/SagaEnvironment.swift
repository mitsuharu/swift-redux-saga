/// Saga から見た、State・Action の読み書きの相手。
///
/// 子の State・Action で書いた Saga（scope）では、親の環境を子の型に付け替えたものを使う。
/// ランタイムを分けずに型だけを付け替えるのは、fork / spawn / キャンセル / エラーの伝わり方を、
/// scope を通しても通さなくても同じにするため（ランタイムを分けると、子のランタイムの寿命を別に管理する必要がある）。
struct SagaEnvironment<State: Sendable, Action: Sendable>: Sendable {
  /// State を読み、Action を発行する相手。
  let host: any SagaHost<State, Action>
  /// 発行された Action を受け取る口。
  let actions: any SagaActionSource<Action>

  /// 子の State・Action に付け替えた環境を返す。
  func scoped<ChildState: Sendable, ChildAction: Sendable>(
    state: @escaping @Sendable (State) -> ChildState,
    action: @escaping @Sendable (Action) -> ChildAction?,
    embed: @escaping @Sendable (ChildAction) -> Action
  ) -> SagaEnvironment<ChildState, ChildAction> {
    SagaEnvironment<ChildState, ChildAction>(
      host: ScopedHost(parent: host, state: state, embed: embed),
      actions: ScopedActionSource(parent: actions, extract: action))
  }
}

/// 発行された Action を受け取る口。ランタイムの ActionMulticaster と、それを子の型に付け替えたもの。
protocol SagaActionSource<Action>: Sendable {
  associatedtype Action: Sendable

  /// 次に届く、パターンに一致する Action を待つ。`onWaiting` は待ち始めた（登録した）直後に呼ぶ。
  func take<Value>(
    _ pattern: ActionPattern<Action, Value>, onWaiting: @Sendable () -> Void
  ) async throws -> Value

  /// 届くすべての Action を受け取る購読者を登録する。戻り値の関数で登録を外す。
  func subscribe(_ receive: @escaping @Sendable (Action) -> Void) -> @Sendable () -> Void
}

extension ActionMulticaster: SagaActionSource {}

/// 親の Action から子の Action を取り出して渡す口。
struct ScopedActionSource<ParentAction: Sendable, Action: Sendable>: SagaActionSource {
  let parent: any SagaActionSource<ParentAction>
  let extract: @Sendable (ParentAction) -> Action?

  func take<Value>(
    _ pattern: ActionPattern<Action, Value>, onWaiting: @Sendable () -> Void
  ) async throws -> Value {
    let extract = extract
    return try await parent.take(
      ActionPattern { extract($0).flatMap(pattern.match) }, onWaiting: onWaiting)
  }

  func subscribe(_ receive: @escaping @Sendable (Action) -> Void) -> @Sendable () -> Void {
    let extract = extract
    return parent.subscribe { action in
      if let action = extract(action) { receive(action) }
    }
  }
}

/// 子の型に付け替えた Host。親の Host を通して、子の State を読み、子の Action を親の Action にして発行する。
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
