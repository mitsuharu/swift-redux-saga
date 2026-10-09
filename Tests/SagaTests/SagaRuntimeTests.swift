import InternalPrimitives
import Testing

@testable import Saga

private enum Action: Sendable, Equatable {
  case fetch(Int)
  case loaded(Int)
  case add(Int)
  case other
}

private struct AppState: Sendable, Equatable {
  var total = 0
}

private let fetch = ActionPattern<Action, Int>.case {
  if case .fetch(let id) = $0 { id } else { nil }
}

private func makeHost() -> TestHost<AppState, Action> {
  TestHost(initialState: AppState()) { state, action in
    if case .add(let value) = action { state.total += value }
  }
}

private struct TestError: Error, Equatable {}

@Suite struct SagaRuntimeTests {
  @Test func takeReceivesTheValueOfTheNextMatchingAction() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(
      Saga { ctx in
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded(id))
      })
    await runtime.activity.waitUntilIdle()
    runtime.emit(.other)
    runtime.emit(.fetch(7))
    try await task.join()
    #expect(host.dispatched == [.loaded(7)])
  }

  @Test func takeDoesNotReceiveActionsEmittedBeforeItStartsWaiting() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(
      Saga { ctx in
        _ = try await ctx.take(.action(.other))
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded(id))
      })
    await runtime.activity.waitUntilIdle()
    runtime.emit(.fetch(1))  // まだ .other を待っているので受け取らない
    runtime.emit(.other)
    await runtime.activity.waitUntilIdle()
    #expect(task.isRunning)
    runtime.emit(.fetch(2))
    try await task.join()
    #expect(host.dispatched == [.loaded(2)])
  }

  @Test func oneActionResumesEverySagaWaitingForIt() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let first = runtime.run(Saga { ctx in await ctx.put(.loaded(try await ctx.take(fetch))) })
    let second = runtime.run(Saga { ctx in await ctx.put(.loaded(try await ctx.take(fetch) * 10)) })
    await runtime.activity.waitUntilIdle()
    runtime.emit(.fetch(3))
    try await first.join()
    try await second.join()
    #expect(Set(host.dispatched.map { "\($0)" }) == ["loaded(3)", "loaded(30)"])
  }

  @Test func putReturnsAfterTheHostHasProcessedTheAction() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let seen = Locked<Int?>(nil)
    try await runtime.run(
      Saga { ctx in
        await ctx.put(.add(5))
        let total = await ctx.select { $0.total }
        seen.withLock { $0 = total }
      }
    ).join()
    #expect(seen.withLock { $0 } == 5)
  }

  @Test func putIsDeliveredToSagasWaitingForIt() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let waiter = runtime.run(
      Saga { ctx in
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded(id))
      })
    await runtime.activity.waitUntilIdle()
    try await runtime.run(Saga { ctx in await ctx.put(.fetch(4)) }).join()
    try await waiter.join()
    #expect(host.dispatched == [.fetch(4), .loaded(4)])
  }

  @Test func selectReturnsTheCurrentState() async throws {
    let host = makeHost()
    await host.dispatch(.add(2))
    let runtime = host.makeRuntime()
    let seen = Locked<AppState?>(nil)
    try await runtime.run(
      Saga { ctx in
        seen.withLock { $0 = nil }
        let s = await ctx.select()
        seen.withLock { $0 = s }
      }
    ).join()
    #expect(seen.withLock { $0 } == AppState(total: 2))
  }

  @Test func callPassesTheArgumentsAndReturnsTheResult() async throws {
    @Sendable func multiply(_ a: Int, _ b: Int) async throws -> Int { a * b }
    let host = makeHost()
    let runtime = host.makeRuntime()
    try await runtime.run(
      Saga { ctx in
        let product = try await ctx.call(multiply, 3, 4)
        await ctx.put(.loaded(product))
      }
    ).join()
    #expect(host.dispatched == [.loaded(12)])
  }

  @Test func callRethrowsTheErrorOfTheFunctionAndFailsTheSaga() async {
    @Sendable func fail() async throws -> Int { throw TestError() }
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(Saga { ctx in _ = try await ctx.call(fail) })
    await #expect(throws: TestError.self) { try await task.join() }
    #expect(!task.isRunning)
    #expect(!task.isCancelled)
  }

  @Test func callDoesNotInvokeTheFunctionWhenAlreadyCancelled() async {
    let invoked = Locked(false)
    @Sendable func record() async throws { invoked.withLock { $0 = true } }
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(
      Saga { ctx in
        _ = try await ctx.take(fetch)  // ここでキャンセルされる
        try await ctx.call(record)
      })
    await runtime.activity.waitUntilIdle()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.join() }
    #expect(invoked.withLock { $0 } == false)
  }

  @Test func cancellingASagaWaitingForAnActionRemovesTheWaiter() async {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(Saga { ctx in _ = try await ctx.take(fetch) })
    await runtime.activity.waitUntilIdle()
    #expect(runtime.multicaster.takerCount == 1)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.join() }
    #expect(task.isCancelled)
    #expect(runtime.multicaster.takerCount == 0)
    await runtime.activity.waitUntilIdle()
    #expect(runtime.activity.running == 0)
  }

  @Test func catchingCancellationDoesNotKeepTheSagaFromBeingReportedAsCancelled() async {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(
      Saga { ctx in
        do {
          _ = try await ctx.take(fetch)
        } catch is CancellationError {
          #expect(ctx.isCancelled)
        }
      })
    await runtime.activity.waitUntilIdle()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.join() }
    #expect(task.isCancelled)
  }

  @Test func stopCancelsEverySagaAndCancelsSagasStartedLater() async {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let first = runtime.run(Saga { ctx in _ = try await ctx.take(fetch) })
    let second = runtime.run(Saga { ctx in _ = try await ctx.take(fetch) })
    await runtime.activity.waitUntilIdle()
    runtime.stop()
    await #expect(throws: CancellationError.self) { try await first.join() }
    await #expect(throws: CancellationError.self) { try await second.join() }
    let late = runtime.run(Saga { ctx in await ctx.put(.other) })
    await #expect(throws: CancellationError.self) { try await late.join() }
    #expect(host.dispatched.isEmpty)
  }

  @Test func joinReturnsOnceTheSagaCompletes() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(Saga { ctx in await ctx.put(.other) })
    try await task.join()
    try await task.join()  // 終わった後の join もすぐに戻る
    #expect(!task.isRunning)
    #expect(host.dispatched == [.other])
  }

  @Test func cancellingAJoinerDoesNotCancelTheJoinedSaga() async {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let target = runtime.run(Saga { ctx in _ = try await ctx.take(fetch) })
    let joiner = runtime.run(Saga { ctx in try await ctx.join(target) })
    await runtime.activity.waitUntilIdle()
    joiner.cancel()
    await #expect(throws: CancellationError.self) { try await joiner.join() }
    #expect(target.isRunning)
    runtime.emit(.fetch(1))
    await #expect(throws: Never.self) { try await target.join() }
  }

  @Test func waitUntilIdleWaitsForEverySagaToBlockOnAnEffect() async {
    let host = makeHost()
    let runtime = host.makeRuntime()
    for _ in 0..<20 {
      runtime.run(
        Saga { ctx in
          await ctx.put(.add(1))
          _ = try await ctx.take(fetch)
        })
    }
    await runtime.activity.waitUntilIdle()
    #expect(host.currentState.total == 20)
    #expect(runtime.multicaster.takerCount == 20)
    runtime.stop()
  }

  @Test func waitUntilIdleReturnsWhileASagaIsInARealTimeDelay() async throws {
    let host = makeHost()
    let runtime = SagaRuntime(host: host, clock: ContinuousClock())
    runtime.run(
      Saga { ctx in
        while true {
          try await ctx.delay(.seconds(3600))
        }
      })
    // 1 時間の delay の間に戻ることを確かめる（戻らなければテストが終わらない）。
    await runtime.waitUntilIdle()
    #expect(runtime.activity.running == 0)
    runtime.stop()
  }

  @Test func cancellingARealTimeDelayKeepsTheActivityBalanced() async throws {
    let host = makeHost()
    let runtime = SagaRuntime(host: host, clock: ContinuousClock())
    let task = runtime.run(Saga { ctx in try await ctx.delay(.seconds(3600)) })
    await runtime.waitUntilIdle()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.join() }
    await runtime.waitUntilIdle()
    #expect(runtime.activity.running == 0)
  }
}
