import Redux
import ReduxSaga
import Saga
import SagaTesting
import Testing

private enum Action: Sendable, Equatable {
  case request(Int)
  case done(Int)
}

private let reducer = Reducer<Int, Action> { state, action in
  if case .done(let value) = action { state = value }
}

private let request = ActionPattern<Action, Int>.case {
  if case .request(let id) = $0 { id } else { nil }
}

@MainActor
private func eventuallyReleased(_ isReleased: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !isReleased() {
    if ContinuousClock.now > deadline { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

@MainActor
@Suite struct ReduxSagaMemoryTests {
  @Test func storeAndSagaMiddlewareAreReleasedWithRunningSagas() async {
    weak var weakStore: Store<Int, Action>?
    weak var weakMiddleware: SagaMiddleware<Int, Action>?
    var task: SagaTask?
    do {
      // 実時間の delay の間は waitUntilIdle が待ち続けるため、TestClock を使う。
      let middleware = SagaMiddleware<Int, Action>(clock: TestClock())
      let store = Store(initialState: 0, reducer: reducer, middleware: [middleware])
      weakStore = store
      weakMiddleware = middleware
      task = middleware.run(
        Saga { ctx in
          ctx.takeEvery(request) { ctx, id in await ctx.put(.done(id)) }
          ctx.takeLatest(request) { ctx, _ in try await ctx.delay(.seconds(100)) }
        })
      await middleware.waitUntilIdle()
      store.dispatch(.request(1))
      await middleware.waitUntilIdle()
      #expect(store.state == 1)
    }
    #expect(await eventuallyReleased { weakStore == nil })
    #expect(await eventuallyReleased { weakMiddleware == nil })
    // ミドルウェアの解放で Saga が止まる。
    await #expect(throws: CancellationError.self) { try await task?.join() }
  }

  @Test func observationsDoNotKeepTheStoreAlive() async {
    weak var weakStore: Store<Int, Action>?
    var token: ObservationToken?
    var tokens: [ObservationToken] = []
    do {
      let store = Store(initialState: 0, reducer: reducer)
      weakStore = store
      token = store.observe {
        $0.state
      } onChange: { _ in
      }
      tokens.append(
        ObservationToken.observe { [weak store] in
          store?.state ?? 0
        } onChange: { _ in
        })
      var iterator = store.values { $0.state }.makeAsyncIterator()
      _ = await iterator.next()
      store.dispatch(.done(2))
    }
    #expect(await eventuallyReleased { weakStore == nil })
    token?.cancel()
    for token in tokens { token.cancel() }
  }
}
