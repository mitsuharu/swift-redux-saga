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

  @Test func aFailureOfAForkedChildPropagatesToTheCallerLikeAnyFork() async throws {
    let failing = Saga<TodoState, TodoAction>("failing") { ctx in
      _ = try await ctx.take(add)
      throw TestError()
    }
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga<AppState, AppAction>("app") { ctx in
        do {
          try await ctx.join(
            ctx.fork(failing, state: \.todo, action: \.todo, embed: AppAction.todo))
        } catch is TestError {
          // 機能をモジュールに切り出しても、失敗は通常の fork と同じく呼び出し元で catch できる。
          await ctx.put(.logout)
        }
      })
    await tester.send(.todo(.add("x")))
    try tester.receive(.logout)
    let errors = tester.errors
    #expect(errors.count == 1)
    #expect(errors.first?.sagaStack == ["failing", "app"])
    _ = try? await tester.finish()
  }

  @Test func sagasSpawnedFromAScopedSagaKeepReceivingActionsAndStopWithTheRuntime() async throws {
    let host = TestHost<AppState, AppAction>(initialState: AppState(), reducer: reduce)
    let runtime = host.makeRuntime()
    let spawned = Locked<SagaTask?>(nil)
    // 子の根は監視を spawn してすぐ終わる。
    let root = runtime.run(
      Saga<TodoState, TodoAction>("starter") { ctx in
        let watcher = ctx.spawn("watcher") { ctx in
          while true {
            let title = try await ctx.take(add)
            await ctx.put(.added(title))
          }
        }
        spawned.withLock { $0 = watcher }
      },
      state: \.todo, action: \.todo, embed: AppAction.todo)
    try await root.join()
    runtime.emit(.todo(.add("milk")))
    await runtime.waitUntilIdle()
    #expect(host.dispatched == [.todo(.added("milk"))])

    runtime.stop()
    let watcher = try #require(spawned.withLock { $0 })
    await #expect(throws: CancellationError.self) { try await watcher.join() }
  }

  @Test func joiningTheCallerWaitsForTheCleanupOfACancelledScopedChild() async throws {
    let cleanedUp = Locked(false)
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga<AppState, AppAction> { ctx in
        let session = ctx.fork { ctx in
          ctx.fork(
            Saga<TodoState, TodoAction> { ctx in
              do {
                _ = try await ctx.take(add)
              } catch is CancellationError {
                // キャンセルの後に、時間のかかる後始末をする。
                try? await Task.sleep(for: .zero)
                await ctx.put(.added("cleanup"))
                cleanedUp.withLock { $0 = true }
                throw CancellationError()
              }
            },
            state: \.todo, action: \.todo, embed: AppAction.todo)
        }
        _ = try await ctx.take(.action(.logout))
        ctx.cancel(session)
        _ = try? await ctx.join(session)
        // 親の join から戻った時点で、配下の子の後始末も終わっている。
        await ctx.put(cleanedUp.withLock { $0 } ? .login : .logout)
      })
    await tester.send(.logout)
    #expect(tester.unreceivedActions == [.todo(.added("cleanup")), .login])
    tester.skipReceivedActions()
    try await tester.finish()
  }
}
