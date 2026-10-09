import InternalPrimitives
import Saga
import SagaTesting
import Testing

// 子（Todo）の State・Action。親を知らない。
private struct TodoState: Sendable, Equatable {
  var titles: [String] = []
}

private enum TodoAction: Sendable, Equatable {
  case add(String)
  case added(String)
}

// 親（App）の State・Action。
private struct AppState: Sendable, Equatable {
  var todo = TodoState()
  var isLoggedIn = false
}

private enum AppAction: Sendable, Equatable {
  case todo(TodoAction)
  case login
  case logout

  var todo: TodoAction? {
    if case .todo(let action) = self { action } else { nil }
  }
}

private let reduce: @Sendable (inout AppState, AppAction) -> Void = { state, action in
  switch action {
  case .todo(.added(let title)): state.todo.titles.append(title)
  case .todo(.add): break
  case .login: state.isLoggedIn = true
  case .logout: state.isLoggedIn = false
  }
}

private let add = ActionPattern<TodoAction, String>.case {
  if case .add(let title) = $0 { title } else { nil }
}

private struct TestError: Error {}

/// 子の型だけで書いた Saga。追加したら、State の件数を添えて added を発行する。
private let todoSaga = Saga<TodoState, TodoAction>("todo") { ctx in
  ctx.takeEvery(add) { ctx, title in
    let count = await ctx.select(\.titles.count)
    await ctx.put(.added("\(title) #\(count + 1)"))
  }
}

@Suite struct ScopeTests {
  @Test func aChildSagaRunsWithItsOwnStateAndActions() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga<AppState, AppAction> { ctx in
        ctx.fork(todoSaga, state: \.todo, action: \.todo, embed: AppAction.todo)
      })
    await tester.send(.todo(.add("milk")))
    try tester.receive(.todo(.added("milk #1")))
    await tester.send(.todo(.add("bread")))
    try tester.receive(.todo(.added("bread #2")))
    #expect(tester.state.todo.titles == ["milk #1", "bread #2"])
    try await tester.finish()
  }

  @Test func cancellingTheForkedChildStopsItAndItNoLongerReceivesActions() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga<AppState, AppAction> { ctx in
        while true {
          _ = try await ctx.take(.action(.login))
          let session = ctx.fork(todoSaga, state: \.todo, action: \.todo, embed: AppAction.todo)
          _ = try await ctx.take(.action(.logout))
          ctx.cancel(session)
        }
      })
    await tester.send(.login)
    await tester.send(.todo(.add("milk")))
    try tester.receive(.todo(.added("milk #1")))
    await tester.send(.logout)
    await tester.send(.todo(.add("ignored")))
    #expect(tester.unreceivedActions.isEmpty)
    // 再ログインで、子の Saga を起動し直せる。
    await tester.send(.login)
    await tester.send(.todo(.add("bread")))
    try tester.receive(.todo(.added("bread #2")))
    try await tester.finish()
  }

  @Test func stoppingTheRuntimeStopsChildSagas() async throws {
    let host = TestHost<AppState, AppAction>(initialState: AppState(), reducer: reduce)
    let runtime = host.makeRuntime()
    let child = runtime.run(todoSaga, state: \.todo, action: \.todo, embed: AppAction.todo)
    await runtime.waitUntilIdle()
    #expect(child.isRunning)
    runtime.stop()
    await #expect(throws: CancellationError.self) { try await child.join() }
  }

  @Test func anActionSentRightAfterRunningAChildReachesIt() async throws {
    let host = TestHost<AppState, AppAction>(initialState: AppState(), reducer: reduce)
    let runtime = host.makeRuntime()
    runtime.run(todoSaga, state: \.todo, action: \.todo, embed: AppAction.todo)
    runtime.emit(.todo(.add("milk")))
    await runtime.waitUntilIdle()
    #expect(host.dispatched == [.todo(.added("milk #1"))])
    runtime.stop()
  }

  @Test func aFailureOfAForkedChildIsReportedOnceAndDoesNotStopTheParent() async throws {
    let failing = Saga<TodoState, TodoAction>("failing") { ctx in
      _ = try await ctx.take(add)
      throw TestError()
    }
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga<AppState, AppAction> { ctx in
        ctx.fork(failing, state: \.todo, action: \.todo, embed: AppAction.todo)
        _ = try await ctx.take(.action(.logout))
        await ctx.put(.login)
      })
    await tester.send(.todo(.add("x")))
    #expect(tester.errors.count == 1)
    await tester.send(.logout)
    try tester.receive(.login)
    #expect(tester.isRunning == false)
    _ = try? await tester.finish()
  }
}
