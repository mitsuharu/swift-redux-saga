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

  @Test func actionsEmittedBeforeTheFirstSagaStartsWaitingAreDeliveredInOrder() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    runtime.run(
      Saga { ctx in
        ctx.takeEvery(fetch) { ctx, id in await ctx.put(.loaded(id)) }
      })
    // Saga が動き出す前（View の表示時など）に emit する。
    runtime.emit(.fetch(1))
    runtime.emit(.fetch(2))
    runtime.emit(.fetch(3))
    await runtime.waitUntilIdle()
    // ワーカーは並行に動くので、届いた順ではなく、すべて届いたことを確かめる。
    let loaded = host.dispatched.compactMap { action -> Int? in
      if case .loaded(let id) = action { id } else { nil }
    }
    #expect(loaded.sorted() == [1, 2, 3])
    runtime.stop()
  }

  @Test func actionsEmittedBeforeTheFirstSagaStartsWaitingReachASequentialTake() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(
      Saga { ctx in
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded(id))
      })
    runtime.emit(.fetch(1))
    try await task.join()
    #expect(host.dispatched == [.loaded(1)])
  }

  @Test func actionsAreNotBufferedOnceTheSagasHaveStarted() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    runtime.run(Saga { ctx in _ = try await ctx.take(.action(.other)) })
    await runtime.waitUntilIdle()
    // 起動後に run した Saga は、待ち始める前の Action を受け取らない（溜めるのは最初の起動の間だけ）。
    let late = runtime.run(
      Saga { ctx in
        let id = try await ctx.take(fetch)
        await ctx.put(.loaded(id))
      })
    await runtime.waitUntilIdle()
    runtime.emit(.fetch(2))
    try await late.join()
    #expect(host.dispatched == [.loaded(2)])
    runtime.stop()
  }

  @Test func stoppingDuringStartupDoesNotKeepBufferingForever() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let task = runtime.run(Saga { ctx in _ = try await ctx.take(fetch) })
    runtime.emit(.other)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.join() }
    await runtime.waitUntilIdle()
    #expect(runtime.activity.running == 0)
  }

  @Test func aLongCallAtStartupDoesNotDelayActionsForSagasAlreadyWaiting() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let (handled, continuation) = AsyncStream.makeStream(of: Int.self)
    runtime.run(
      Saga { ctx in
        ctx.takeEvery(fetch) { _, id in continuation.yield(id) }
        // 起動時の長い処理（通信など）。終わるまで待たずに、上の takeEvery に Action が届く。
        try await ctx.call { try await Task.sleep(for: .seconds(3600)) }
      })
    runtime.emit(.fetch(1))
    var iterator = handled.makeAsyncIterator()
    #expect(await iterator.next() == 1)
    runtime.stop()
  }

  @Test func actionsWaitUntilForkedChildrenStartedDuringStartupReachTheirFirstEffect() async throws
  {
    let host = makeHost()
    let runtime = host.makeRuntime()
    runtime.run(
      Saga { ctx in
        ctx.fork { ctx in
          let id = try await ctx.take(fetch)
          await ctx.put(.loaded(id))
        }
      })
    runtime.emit(.fetch(1))
    await runtime.waitUntilIdle()
    #expect(host.dispatched == [.loaded(1)])
    runtime.stop()
  }

  @Test func callDoesNotReturnTheResultOfAFunctionThatFinishedAfterCancellation() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let gate = Locked<CheckedContinuation<Int, Never>?>(nil)
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = runtime.run(
      Saga { ctx in
        // キャンセルに応じない関数（コールバックを async にしたものなど）。
        let value = try await ctx.call { () async -> Int in
          await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
            startedContinuation.yield()
          }
        }
        await ctx.put(.loaded(value))
      })
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    gate.withLock { $0 }?.resume(returning: 1)
    await #expect(throws: CancellationError.self) { try await task.join() }
    #expect(host.dispatched.isEmpty)
  }

  @Test func takeLatestDoesNotPutAnOlderResultAfterANewerOne() async throws {
    let host = makeHost()
    let runtime = host.makeRuntime()
    let gates = Locked<[Int: CheckedContinuation<Int, Never>]>([:])
    let (started, startedContinuation) = AsyncStream.makeStream(of: Int.self)
    let (completed, completedContinuation) = AsyncStream.makeStream(of: Void.self)
    runtime.run(
      Saga { ctx in
        ctx.takeLatest(fetch) { ctx, id in
          // キャンセルに応じない関数（コールバックを async にしたものなど）。
          let result = try await ctx.call { () async -> Int in
            await withCheckedContinuation { continuation in
              gates.withLock { $0[id] = continuation }
              startedContinuation.yield(id)
            }
          }
          await ctx.put(.loaded(result))
          completedContinuation.yield()
        }
      })
    await runtime.waitUntilIdle()
    var startedIterator = started.makeAsyncIterator()
    runtime.emit(.fetch(1))
    #expect(await startedIterator.next() == 1)
    runtime.emit(.fetch(2))
    #expect(await startedIterator.next() == 2)
    // 新しい結果が先に、古い結果が後に戻る。
    gates.withLock { $0.removeValue(forKey: 2) }?.resume(returning: 102)
    var completedIterator = completed.makeAsyncIterator()
    await completedIterator.next()
    gates.withLock { $0.removeValue(forKey: 1) }?.resume(returning: 101)
    await runtime.waitUntilIdle()
    #expect(host.dispatched == [.loaded(102)])
    runtime.stop()
  }
}
