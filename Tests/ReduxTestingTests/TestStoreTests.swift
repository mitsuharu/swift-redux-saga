import Redux
import ReduxTesting
import Saga
import Testing

private struct AppState: Sendable, Equatable {
  var count = 0
  var isLoading = false
}

private enum Action: Sendable, Equatable {
  case increment
  case fetch
  case loaded(Int)
}

private struct TestError: Error {}

private let reducer = Reducer<AppState, Action> { state, action in
  switch action {
  case .increment:
    state.count += 1
  case .fetch:
    state.isLoading = true
  case .loaded(let value):
    state.isLoading = false
    state.count = value
  }
}

private func fetchSaga(delay: Duration = .zero, load: @escaping @Sendable () async throws -> Int)
  -> Saga<AppState, Action>
{
  Saga { ctx in
    ctx.takeLatest(.action(.fetch)) { ctx, _ in
      if delay > .zero { try await ctx.delay(delay) }
      await ctx.put(.loaded(try await ctx.call(load)))
    }
  }
}

@MainActor
@Suite struct TestStoreTests {
  @Test func sendChecksTheStateRightAfterTheReducer() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer)
    try await store.send(.increment) { $0.count = 1 }
    try await store.send(.increment) { $0.count = 2 }
    try await store.finish()
  }

  @Test func sendFailsWhenTheStateDoesNotMatch() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer)
    await #expect(throws: TestStoreFailure.self) {
      try await store.send(.increment) { $0.count = 5 }
    }
  }

  @Test func receiveChecksActionsPutBySagasAndTheirStateChanges() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer, saga: fetchSaga { 42 })
    try await store.send(.fetch) { $0.isLoading = true }
    try store.receive(.loaded(42)) {
      $0.isLoading = false
      $0.count = 42
    }
    try await store.finish()
  }

  @Test func advanceRunsDelayedSagas() async throws {
    let store = TestStore(
      initialState: AppState(), reducer: reducer, saga: fetchSaga(delay: .seconds(1)) { 7 })
    try await store.send(.fetch) { $0.isLoading = true }
    #expect(store.unreceivedActions.isEmpty)
    await store.advance(by: .seconds(1))
    try store.receive(.loaded(7)) {
      $0.isLoading = false
      $0.count = 7
    }
    try await store.finish()
  }

  @Test func receiveWithAPatternReturnsTheExtractedValue() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer, saga: fetchSaga { 3 })
    try await store.send(.fetch)
    let value = try store.receive(.case { if case .loaded(let v) = $0 { v } else { nil } })
    #expect(value == 3)
    try await store.finish()
  }

  @Test func finishFailsWhenSomeActionsWereNotReceived() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer, saga: fetchSaga { 1 })
    try await store.send(.fetch)
    await #expect(throws: TestStoreFailure.self) { try await store.finish() }
  }

  @Test func finishFailsWhenASagaFailedWithAnUnhandledError() async throws {
    let store = TestStore(
      initialState: AppState(), reducer: reducer, saga: fetchSaga { throw TestError() })
    try await store.send(.fetch)
    #expect(store.sagaErrors.first?.underlying is TestError)
    await #expect(throws: TestStoreFailure.self) { try await store.finish() }
  }

  @Test func skipReceivedActionsMovesTheCheckedStateForward() async throws {
    let store = TestStore(initialState: AppState(), reducer: reducer, saga: fetchSaga { 9 })
    try await store.send(.fetch)
    store.skipReceivedActions()
    try await store.send(.increment) { $0.count = 10 }
    try await store.finish()
  }
}
