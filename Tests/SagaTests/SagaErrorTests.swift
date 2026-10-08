import InternalPrimitives
import Testing

@testable import Saga

private enum Action: Sendable, Equatable {
  case start
  case done
}

private struct TestError: Error, Equatable {}

private let start = ActionPattern<Action, Action>.action(.start)

/// onError に渡されたエラーを記録する。
private final class ErrorRecorder: Sendable {
  private let errors = Locked<[SagaError]>([])
  var recorded: [SagaError] { errors.withLock { $0 } }
  func record(_ error: SagaError) { errors.withLock { $0.append(error) } }
}

/// モニタに通知された出来事を記録する。
private final class MonitorRecorder: SagaMonitor {
  enum Event: Sendable, Equatable {
    case started(SagaID, String?, parent: SagaID?)
    case finished(SagaID, String)
    case effect(SagaID, String)
  }

  private let storage = Locked<[Event]>([])
  var events: [Event] { storage.withLock { $0 } }

  func sagaStarted(_ id: SagaID, name: String?, parent: SagaID?) {
    storage.withLock { $0.append(.started(id, name, parent: parent)) }
  }

  func sagaFinished(_ id: SagaID, result: SagaResult) {
    let result =
      switch result {
      case .completed: "completed"
      case .cancelled: "cancelled"
      case .failed: "failed"
      }
    storage.withLock { $0.append(.finished(id, result)) }
  }

  func effectTriggered(_ id: SagaID, effect: SagaEffect) {
    storage.withLock { $0.append(.effect(id, "\(effect)")) }
  }
}

private func makeRuntime(
  monitor: (any SagaMonitor)? = nil, errors: ErrorRecorder = ErrorRecorder()
) -> SagaRuntime<Int, Action> {
  let host = TestHost<Int, Action>(initialState: 0) { _, _ in }
  let runtime = SagaRuntime(host: host, monitor: monitor, onError: errors.record)
  return runtime
}

@Suite struct SagaErrorTests {
  @Test func anErrorReachingTheRootIsReportedWithThePathOfSagas() async {
    let errors = ErrorRecorder()
    let runtime = makeRuntime(errors: errors)
    let child = Saga<Int, Action>("child") { _ in throw TestError() }
    let root = runtime.run(
      Saga("root") { ctx in ctx.fork(Saga("middle") { ctx in ctx.fork(child) }) })
    await #expect(throws: TestError.self) { try await root.join() }
    #expect(errors.recorded.count == 1)
    #expect(errors.recorded.first?.underlying is TestError)
    #expect(errors.recorded.first?.sagaStack == ["child", "middle", "root"])
  }

  @Test func unnamedSagasAppearAsAnonymousInThePath() async {
    let errors = ErrorRecorder()
    let runtime = makeRuntime(errors: errors)
    let root = runtime.run(Saga { _ in throw TestError() })
    await #expect(throws: TestError.self) { try await root.join() }
    #expect(errors.recorded.first?.sagaStack == ["anonymous"])
  }

  @Test func aFailingSpawnedSagaIsReportedOnItsOwn() async throws {
    let errors = ErrorRecorder()
    let runtime = makeRuntime(errors: errors)
    let root = runtime.run(
      Saga("root") { ctx in
        let spawned = ctx.spawn(Saga("spawned") { _ in throw TestError() })
        _ = try? await ctx.join(spawned)
      })
    try await root.join()
    #expect(errors.recorded.map(\.sagaStack) == [["spawned"]])
  }

  @Test func cancellationIsNotReportedAsAnError() async {
    let errors = ErrorRecorder()
    let runtime = makeRuntime(errors: errors)
    let root = runtime.run(Saga { ctx in ctx.fork { ctx in _ = try await ctx.take(start) } })
    await runtime.activity.waitUntilIdle()
    root.cancel()
    await #expect(throws: CancellationError.self) { try await root.join() }
    #expect(errors.recorded.isEmpty)
  }

  @Test func anErrorCaughtInsideTheSagaIsNotReported() async throws {
    let errors = ErrorRecorder()
    let runtime = makeRuntime(errors: errors)
    @Sendable func fail() async throws { throw TestError() }
    try await runtime.run(Saga { ctx in try? await ctx.call(fail) }).join()
    #expect(errors.recorded.isEmpty)
  }

  @Test func monitorReceivesTheLifecycleAndEffectsOfSagas() async throws {
    let monitor = MonitorRecorder()
    let runtime = makeRuntime(monitor: monitor)
    let root = runtime.run(
      Saga("root") { ctx in
        let child = ctx.fork(Saga("child") { ctx in await ctx.put(.done) })
        try await ctx.join(child)
      })
    try await root.join()
    let rootID = root.id
    let events = monitor.events
    let childID = try #require(
      events.compactMap { event -> SagaID? in
        if case .started(let id, "child", parent: rootID) = event { id } else { nil }
      }.first)
    #expect(events.first == .started(rootID, "root", parent: nil))
    #expect(events.contains(.effect(rootID, "fork(\(childID))")))
    #expect(events.contains(.effect(childID, "put(\"done\")")))
    #expect(events.contains(.effect(rootID, "join(\(childID))")))
    #expect(events.contains(.finished(childID, "completed")))
    #expect(events.last == .finished(rootID, "completed"))
  }

  @Test func monitorReceivesCancelledAndFailedResults() async {
    let monitor = MonitorRecorder()
    let runtime = makeRuntime(monitor: monitor)
    let cancelled = runtime.run(Saga { ctx in _ = try await ctx.take(start) })
    let failed = runtime.run(Saga { _ in throw TestError() })
    await runtime.activity.waitUntilIdle()
    cancelled.cancel()
    _ = try? await cancelled.join()
    _ = try? await failed.join()
    #expect(monitor.events.contains(.finished(cancelled.id, "cancelled")))
    #expect(monitor.events.contains(.finished(failed.id, "failed")))
  }
}
