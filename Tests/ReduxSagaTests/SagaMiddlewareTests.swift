import InternalPrimitives
import Redux
import ReduxSaga
import Saga
import Testing

private enum Action: Sendable, Equatable {
  case fetch(Int)
  case loaded(String)
  case increment
}

private struct AppState: Sendable, Equatable {
  var count = 0
  var name = ""
}

private let reducer = Reducer<AppState, Action> { state, action in
  switch action {
  case .increment: state.count += 1
  case .loaded(let name): state.name = name
  case .fetch: break
  }
}

private let fetch = ActionPattern<Action, Int>.case {
  if case .fetch(let id) = $0 { id } else { nil }
}

@MainActor
@Suite struct SagaMiddlewareTests {
  private func makeStore() -> (Store<AppState, Action>, SagaMiddleware<AppState, Action>) {
    let middleware = SagaMiddleware<AppState, Action>()
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])
    return (store, middleware)
  }

  private func settle(_ middleware: SagaMiddleware<AppState, Action>) async {
    await middleware.waitUntilIdle()
  }

  @Test func anActionDispatchedRightAfterRunReachesTheSaga() async {
    let (store, middleware) = makeStore()
    middleware.run(
      Saga { ctx in
        ctx.takeEvery(fetch) { ctx, id in await ctx.put(.loaded("user \(id)")) }
      })
    // run の直後（View の onAppear など、Saga が動き出す前）に dispatch する。
    store.dispatch(.fetch(1))
    await settle(middleware)
    #expect(store.name == "user 1")
  }

  @Test func aSagaReactsToADispatchedActionAndPutsItsResultIntoTheStore() async {
    let (store, middleware) = makeStore()
    middleware.run(
      Saga { ctx in
        while true {
          let id = try await ctx.take(fetch)
          await ctx.put(.loaded("user\(id)"))
        }
      })
    await settle(middleware)
    store.dispatch(.fetch(1))
    await settle(middleware)
    #expect(store.name == "user1")
  }

  @Test func aSagaReceivesTheActionAfterTheReducerHasRun() async {
    let (store, middleware) = makeStore()
    let seen = Locked<Int?>(nil)
    middleware.run(
      Saga { ctx in
        _ = try await ctx.take(.action(.increment))
        let count = await ctx.select { $0.count }
        seen.withLock { $0 = count }
      })
    await settle(middleware)
    store.dispatch(.increment)
    await settle(middleware)
    #expect(seen.withLock { $0 } == 1)
  }

  @Test func putReturnsAfterTheStoreHasBeenUpdated() async throws {
    let (store, middleware) = makeStore()
    let seen = Locked<AppState?>(nil)
    try await middleware.run(
      Saga { ctx in
        await ctx.put(.increment)
        await ctx.put(.increment)
        let state = await ctx.select()
        seen.withLock { $0 = state }
      }
    ).join()
    #expect(seen.withLock { $0 } == AppState(count: 2))
    #expect(store.count == 2)
  }

  @Test func putGoesThroughTheWholeMiddlewareChainAndReachesOtherSagas() async {
    let (store, middleware) = makeStore()
    middleware.run(
      Saga { ctx in
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded("user\(id)"))
      })
    await settle(middleware)
    middleware.run(Saga { ctx in await ctx.put(.fetch(7)) })
    await settle(middleware)
    #expect(store.name == "user7")
  }

  @Test func stopCancelsRunningSagas() async {
    let (_, middleware) = makeStore()
    let task = middleware.run(Saga { ctx in _ = try await ctx.take(fetch) })
    await settle(middleware)
    middleware.stop()
    await #expect(throws: CancellationError.self) { try await task.join() }
  }

  @Test func releasingTheStoreCancelsRunningSagas() async {
    let (task, weakStore) = await startSagaOnATemporaryStore()
    #expect(weakStore() == nil)
    await #expect(throws: CancellationError.self) { try await task.join() }
  }

  /// Store とミドルウェアを関数の中だけで持ち、Saga を起動して返す。
  private func startSagaOnATemporaryStore() async -> (
    SagaTask, () -> Store<AppState, Action>?
  ) {
    let middleware = SagaMiddleware<AppState, Action>()
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])
    weak let weakStore = store
    let task = middleware.run(Saga { ctx in _ = try await ctx.take(fetch) })
    await settle(middleware)
    return (task, { weakStore })
  }
}
