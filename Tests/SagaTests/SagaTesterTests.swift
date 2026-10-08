import Saga
import SagaTesting
import Testing

private enum Action: Sendable, Equatable {
  case fetch(Int)
  case loaded(String)
  case tick
  case increment
}

private struct AppState: Sendable, Equatable {
  var count = 0
  var name = ""
}

private struct TestError: Error {}

@Sendable private func reduce(_ state: inout AppState, _ action: Action) {
  switch action {
  case .increment: state.count += 1
  case .loaded(let name): state.name = name
  case .fetch, .tick: break
  }
}

private let fetch = ActionPattern<Action, Int>.case {
  if case .fetch(let id) = $0 { id } else { nil }
}

/// テスト対象のロジック。本ライブラリに依存しない関数として書く。
private struct FetchName: Sendable {
  let execute: @Sendable (Int) async throws -> String
}

private func fetchSaga(_ fetchName: FetchName) -> Saga<AppState, Action> {
  Saga("fetch") { ctx in
    while true {
      let id = try await ctx.take(fetch)
      let name = try await ctx.call(fetchName.execute, id)
      await ctx.put(.loaded(name))
    }
  }
}

@Suite struct SagaTesterTests {
  @Test func sendDeliversTheActionAndWaitsForTheSagaToPutItsResult() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    await tester.send(.fetch(1))
    try tester.receive(.loaded("user1"))
    #expect(tester.state.name == "user1")
    await tester.send(.fetch(2))
    try tester.receive(.loaded("user2"))
    try await tester.finish()
  }

  @Test func sendAppliesTheActionToTheState() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce, saga: Saga { ctx in _ = try await ctx.take() })
    await tester.send(.increment)
    #expect(tester.state.count == 1)
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }

  @Test func receiveWithAPatternReturnsTheExtractedValue() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    await tester.send(.fetch(3))
    let name = try tester.receive(.case { if case .loaded(let name) = $0 { name } else { nil } })
    #expect(name == "user3")
    try await tester.finish()
  }

  @Test func receiveFailsWhenTheActionDiffers() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    await tester.send(.fetch(1))
    #expect(throws: SagaTesterFailure.self) { try tester.receive(.loaded("someone else")) }
    try await tester.finish()
  }

  @Test func receiveFailsWhenNoActionWasPut() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    #expect(throws: SagaTesterFailure.self) { try tester.receive(.loaded("user1")) }
    try await tester.finish()
  }

  @Test func finishFailsWhenSomeActionsWereNotReceived() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    await tester.send(.fetch(1))
    await #expect(throws: SagaTesterFailure.self) { try await tester.finish() }
  }

  @Test func skipReceivedActionsDiscardsUncheckedActions() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { "user\($0)" }))
    await tester.send(.fetch(1))
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func finishFailsWhenTheSagaFailedWithAnUnhandledError() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: fetchSaga(FetchName { _ in throw TestError() }))
    await tester.send(.fetch(1))
    #expect(!tester.isRunning)
    #expect(tester.errors.first?.underlying is TestError)
    #expect(tester.errors.first?.sagaStack == ["fetch"])
    await #expect(throws: SagaTesterFailure.self) { try await tester.finish() }
  }

  @Test func advanceWakesDelayedSagasWithoutWaitingInRealTime() async throws {
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga { ctx in
        while true {
          try await ctx.delay(.seconds(1))
          await ctx.put(.tick)
        }
      })
    await tester.advance(by: .milliseconds(999))
    #expect(tester.unreceivedActions.isEmpty)
    await tester.advance(by: .milliseconds(1))
    try tester.receive(.tick)
    await tester.advance(by: .seconds(3))  // 範囲内で続けて眠る Saga も起こす
    #expect(tester.unreceivedActions == [.tick, .tick, .tick])
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func delayIsCancelledWithTheSaga() async throws {
    let clock = TestClock()
    let tester = SagaTester(
      initialState: AppState(), reduce: reduce,
      saga: Saga { ctx in
        let child = ctx.fork { ctx in
          try await ctx.delay(.seconds(10))
          await ctx.put(.tick)
        }
        _ = try await ctx.take(.action(.increment))
        ctx.cancel(child)
      },
      clock: clock)
    await tester.settle()
    #expect(clock.sleeperCount == 1)
    await tester.send(.increment)
    #expect(clock.sleeperCount == 0)
    await tester.advance(by: .seconds(10))
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }
}
