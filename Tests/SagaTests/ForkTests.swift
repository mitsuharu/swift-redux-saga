import InternalPrimitives
import Testing

@testable import Saga

private enum Action: Sendable, Equatable {
  case start
  case done(String)
}

private struct TestError: Error, Equatable {}

private let start = ActionPattern<Action, Action>.action(.start)

private func makeRuntime() -> (TestHost<Int, Action>, SagaRuntime<Int, Action>) {
  let host = TestHost<Int, Action>(initialState: 0) { _, _ in }
  return (host, host.makeRuntime())
}

/// Saga の中で作った SagaTask を、テストから参照するための入れ物。
private final class TaskBox: Sendable {
  private let storage = Locked<[String: SagaTask]>([:])
  subscript(name: String) -> SagaTask? {
    get { storage.withLock { $0[name] } }
    set { storage.withLock { $0[name] = newValue } }
  }
}

@Suite struct ForkTests {
  @Test func forkDoesNotBlockTheCaller() async throws {
    let (host, runtime) = makeRuntime()
    let parent = runtime.run(
      Saga { ctx in
        ctx.fork { ctx in
          _ = try await ctx.take(start)
          await ctx.put(.done("child"))
        }
        await ctx.put(.done("parent"))
      })
    await runtime.activity.waitUntilIdle()
    #expect(host.dispatched == [.done("parent")])
    #expect(parent.isRunning)  // 子が終わるまで親は完了しない
    runtime.emit(.start)
    try await parent.join()
    #expect(host.dispatched == [.done("parent"), .done("child")])
  }

  @Test func cancellingTheParentCancelsItsChildren() async {
    let (_, runtime) = makeRuntime()
    let tasks = TaskBox()
    let parent = runtime.run(
      Saga { ctx in
        tasks["child"] = ctx.fork { ctx in
          tasks["grandchild"] = ctx.fork { ctx in _ = try await ctx.take(start) }
          _ = try await ctx.take(start)
        }
        _ = try await ctx.take(start)
      })
    await runtime.activity.waitUntilIdle()
    parent.cancel()
    await #expect(throws: CancellationError.self) { try await parent.join() }
    #expect(tasks["child"]?.isCancelled == true)
    #expect(tasks["grandchild"]?.isCancelled == true)
    #expect(runtime.multicaster.takerCount == 0)
  }

  @Test func aFailingChildCancelsItsSiblingsAndFailsTheParent() async {
    let (_, runtime) = makeRuntime()
    let tasks = TaskBox()
    let parent = runtime.run(
      Saga { ctx in
        tasks["sibling"] = ctx.fork { ctx in _ = try await ctx.take(start) }
        tasks["failing"] = ctx.fork { ctx in
          _ = try await ctx.take(.action(.done("fail")))
          throw TestError()
        }
        _ = try await ctx.take(start)
      })
    await runtime.activity.waitUntilIdle()
    runtime.emit(.done("fail"))
    await #expect(throws: TestError.self) { try await parent.join() }
    #expect(tasks["sibling"]?.isCancelled == true)
    #expect(tasks["failing"]?.isCancelled == false)
    await #expect(throws: TestError.self) { try await tasks["failing"]?.join() }
    #expect(runtime.multicaster.takerCount == 0)
  }

  @Test func cancellingAChildDoesNotAffectTheParent() async throws {
    let (host, runtime) = makeRuntime()
    let parent = runtime.run(
      Saga { ctx in
        let child = ctx.fork { ctx in _ = try await ctx.take(start) }
        ctx.cancel(child)
        await #expect(throws: CancellationError.self) { try await ctx.join(child) }
        await ctx.put(.done("parent"))
      })
    try await parent.join()
    #expect(host.dispatched == [.done("parent")])
  }

  @Test func joinWaitsForAForkedChild() async throws {
    let (host, runtime) = makeRuntime()
    let parent = runtime.run(
      Saga { ctx in
        let child = ctx.fork { ctx in
          _ = try await ctx.take(start)
          await ctx.put(.done("child"))
        }
        try await ctx.join(child)
        await ctx.put(.done("parent"))
      })
    await runtime.activity.waitUntilIdle()
    #expect(host.dispatched.isEmpty)
    runtime.emit(.start)
    try await parent.join()
    #expect(host.dispatched == [.done("child"), .done("parent")])
  }

  @Test func spawnedSagaSurvivesTheCancellationOfItsCaller() async throws {
    let (host, runtime) = makeRuntime()
    let tasks = TaskBox()
    let parent = runtime.run(
      Saga { ctx in
        tasks["spawned"] = ctx.spawn { ctx in
          _ = try await ctx.take(start)
          await ctx.put(.done("spawned"))
        }
        _ = try await ctx.take(start)
      })
    await runtime.activity.waitUntilIdle()
    parent.cancel()
    await #expect(throws: CancellationError.self) { try await parent.join() }
    runtime.emit(.start)
    try await tasks["spawned"]?.join()
    #expect(host.dispatched == [.done("spawned")])
  }

  @Test func aFailingSpawnedSagaDoesNotFailItsCaller() async throws {
    let (host, runtime) = makeRuntime()
    let tasks = TaskBox()
    let parent = runtime.run(
      Saga { ctx in
        tasks["spawned"] = ctx.spawn { _ in throw TestError() }
        await #expect(throws: TestError.self) { try await ctx.join(tasks["spawned"]!) }
        await ctx.put(.done("parent"))
      })
    try await parent.join()
    #expect(host.dispatched == [.done("parent")])
  }

  @Test func stopCancelsSpawnedSagas() async {
    let (_, runtime) = makeRuntime()
    let tasks = TaskBox()
    runtime.run(
      Saga { ctx in tasks["spawned"] = ctx.spawn { ctx in _ = try await ctx.take(start) } })
    await runtime.activity.waitUntilIdle()
    runtime.stop()
    await #expect(throws: CancellationError.self) { try await tasks["spawned"]?.join() }
  }

  @Test func forkAfterTheCallerHasFinishedIsCancelledImmediately() async throws {
    let (host, runtime) = makeRuntime()
    let escaped = Locked<SagaContext<Int, Action>?>(nil)
    try await runtime.run(Saga { ctx in escaped.withLock { $0 = ctx } }).join()
    let late = try #require(escaped.withLock { $0 }).fork { ctx in await ctx.put(.done("late")) }
    await #expect(throws: CancellationError.self) { try await late.join() }
    #expect(host.dispatched.isEmpty)
    #expect(runtime.activity.running == 0)
  }

  @Test func combineRunsEverySagaAndCompletesWhenAllHaveCompleted() async throws {
    let (host, runtime) = makeRuntime()
    let a = Saga<Int, Action> { ctx in
      _ = try await ctx.take(start)
      await ctx.put(.done("a"))
    }
    let b = Saga<Int, Action> { ctx in await ctx.put(.done("b")) }
    let root = runtime.run(.combine(a, b))
    await runtime.activity.waitUntilIdle()
    #expect(host.dispatched == [.done("b")])
    #expect(root.isRunning)
    runtime.emit(.start)
    try await root.join()
    #expect(host.dispatched == [.done("b"), .done("a")])
  }

  @Test func manyForksAllRunAndTheParentWaitsForThemAll() async throws {
    let (host, runtime) = makeRuntime()
    try await runtime.run(
      Saga { ctx in
        for i in 0..<100 {
          ctx.fork { ctx in await ctx.put(.done("\(i)")) }
        }
      }
    ).join()
    #expect(host.dispatched.count == 100)
  }
}
