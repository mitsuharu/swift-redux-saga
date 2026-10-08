import Testing

@testable import Saga
@testable import SagaTesting

private enum Action: Sendable, Equatable {
  case fetch(Int)
  case loaded(Int)
  case stop
}

private struct TestError: Error {}

private let fetch = ActionPattern<Action, Int>.case {
  if case .fetch(let id) = $0 { id } else { nil }
}

/// id 秒かけて読み込み、結果を put するワーカー。
@Sendable private func load(_ ctx: SagaContext<Int, Action>, _ id: Int) async throws {
  try await ctx.delay(.seconds(id))
  await ctx.put(.loaded(id))
}

private func makeTester(_ saga: Saga<Int, Action>) -> SagaTester<Int, Action> {
  SagaTester(initialState: 0, reduce: { _, _ in }, saga: saga)
}

@Suite struct TakeHelperTests {
  @Test func takeEveryRunsAWorkerForEveryActionConcurrently() async throws {
    let tester = makeTester(Saga { ctx in ctx.takeEvery(fetch, load) })
    await tester.send(.fetch(2))
    await tester.send(.fetch(1))
    await tester.advance(by: .seconds(1))
    try tester.receive(.loaded(1))
    await tester.advance(by: .seconds(1))
    try tester.receive(.loaded(2))
    try await tester.finish()
  }

  @Test func takeEveryDoesNotMissActionsWhileTheHelperIsBusy() async throws {
    let tester = makeTester(
      Saga { ctx in
        ctx.takeEvery(fetch) { ctx, id in await ctx.put(.loaded(id)) }
      })
    for id in 0..<20 {
      await tester.send(.fetch(id))
    }
    #expect(tester.unreceivedActions == (0..<20).map(Action.loaded))
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func takeLatestCancelsThePreviousWorker() async throws {
    let tester = makeTester(Saga { ctx in ctx.takeLatest(fetch, load) })
    await tester.send(.fetch(3))
    await tester.advance(by: .seconds(1))
    await tester.send(.fetch(3))
    await tester.advance(by: .seconds(2))
    #expect(tester.unreceivedActions.isEmpty)  // 最初のワーカーはキャンセルされた
    await tester.advance(by: .seconds(1))
    try tester.receive(.loaded(3))
    try await tester.finish()
  }

  @Test func takeLeadingIgnoresActionsWhileTheWorkerIsRunning() async throws {
    let tester = makeTester(Saga { ctx in ctx.takeLeading(fetch, load) })
    await tester.send(.fetch(2))
    await tester.send(.fetch(1))  // 実行中なので無視される
    await tester.advance(by: .seconds(2))
    try tester.receive(.loaded(2))
    await tester.send(.fetch(1))  // 終わった後は受け付ける
    await tester.advance(by: .seconds(1))
    try tester.receive(.loaded(1))
    try await tester.finish()
  }

  @Test func cancellingAHelperStopsItsWorkersAndUnsubscribes() async throws {
    let clock = TestClock()
    let tester = SagaTester<Int, Action>(
      initialState: 0, reduce: { _, _ in },
      saga: Saga { ctx in
        let helper = ctx.takeEvery(fetch, load)
        _ = try await ctx.take(.action(.stop))
        ctx.cancel(helper)
      },
      clock: clock)
    await tester.send(.fetch(5))
    #expect(clock.sleeperCount == 1)
    await tester.send(.stop)
    #expect(clock.sleeperCount == 0)
    await tester.send(.fetch(1))
    await tester.advance(by: .seconds(10))
    #expect(tester.unreceivedActions.isEmpty)
    #expect(tester.runtime.multicaster.subscriberCount == 0)
    try await tester.finish()
  }

  @Test func aFailingWorkerFailsTheHelperAndTheCaller() async throws {
    let tester = makeTester(
      Saga("root") { ctx in
        ctx.takeEvery(fetch) { _, _ in throw TestError() }
      })
    await tester.send(.fetch(1))
    #expect(!tester.isRunning)
    #expect(tester.errors.first?.underlying is TestError)
    #expect(tester.errors.first?.sagaStack == ["takeEvery.worker", "takeEvery", "root"])
    await #expect(throws: SagaTesterFailure.self) { try await tester.finish() }
  }
}
