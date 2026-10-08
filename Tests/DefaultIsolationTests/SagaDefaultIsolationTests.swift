import Redux
import ReduxSaga
import Saga
import SagaTesting
import Testing

// default MainActor isolation のモジュールで Saga を書く場合の例。
// Saga の本体は @Sendable なクロージャなので、暗黙に @MainActor にはならず、メインアクター外で動く。

/// ビジネスロジック。本ライブラリに依存しない。
nonisolated struct CounterService: Sendable {
  let load: @Sendable () async throws -> Int
}

nonisolated struct CounterSagas: Sendable {
  let service: CounterService

  var root: Saga<AppState, AppAction> {
    Saga("counter") { ctx in
      while true {
        _ = try await ctx.take(.action(.counter(.increment)))
        let value = try await ctx.call(service.load)
        await ctx.put(.counter(.add(value)))
      }
    }
  }
}

@Suite struct SagaDefaultIsolationTests {
  @Test func sagaMiddlewareWorksWithImplicitlyMainActorCode() async throws {
    let middleware = SagaMiddleware<AppState, AppAction>()
    let store = Store(initialState: AppState(), reducer: appReducer, middleware: [middleware])
    let task = middleware.run(CounterSagas(service: CounterService { 10 }).root)
    // Saga が take で待ち始めるまで待つ（待ち始める前の Action は受け取らないため）。
    await middleware.waitUntilIdle()
    store.dispatch(.counter(.increment))
    let values = store.values { $0.counter.count }
    for await value in values where value == 11 {
      break
    }
    #expect(store.counter.count == 11)
    task.cancel()
  }

  @Test func sagaTesterWorksWithImplicitlyMainActorCode() async throws {
    let tester = SagaTester(
      initialState: AppState(),
      reduce: appReducer.reduce,
      saga: CounterSagas(service: CounterService { 5 }).root
    )
    await tester.send(.counter(.increment))
    try tester.receive(.counter(.add(5)))
    #expect(tester.state.counter.count == 6)
    try await tester.finish()
  }
}
