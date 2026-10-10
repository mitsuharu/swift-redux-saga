import InternalPrimitives
import Testing

@testable import Saga
@testable import SagaTesting

private enum Action: Sendable, Equatable {
  case request(Int)
  case done(Int)
  case stop
}

private let request = ActionPattern<Action, Int>.case {
  if case .request(let id) = $0 { id } else { nil }
}

/// 弱参照が nil になるまで待つ（タスクの後始末は終了の確定の少し後に行われるため）。上限を超えたら false。
func eventuallyReleased(_ isReleased: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !isReleased() {
    if ContinuousClock.now > deadline { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

/// Effect・ヘルパー・チャネル・組み合わせをひととおり使う Saga。
private let everySaga = Saga<Int, Action>("every") { ctx in
  ctx.takeEvery(request) { ctx, id in await ctx.put(.done(id)) }
  ctx.takeLatest(request) { ctx, _ in try await ctx.delay(.seconds(1)) }
  ctx.takeLeading(request) { ctx, _ in try await ctx.delay(.seconds(1)) }
  ctx.debounce(.seconds(1), request) { _, _ in }
  ctx.throttle(.seconds(1), request) { _, _ in }
  let channel = ctx.actionChannel(request)
  ctx.fork { _ in for try await _ in channel {} }
  let events = ctx.eventChannel { (_: @escaping @Sendable (Int) -> Void, _) in {} }
  ctx.fork { _ in for try await _ in events {} }
  ctx.spawn { ctx in _ = try await ctx.take(.action(.stop)) }
  _ = try await ctx.race(
    { ctx in try await ctx.take(.action(.stop)) },
    { ctx in try await ctx.delay(.seconds(100)) }
  )
  _ = try await ctx.all(
    { ctx in try await ctx.take(request) },
    { ctx in try await ctx.delay(.seconds(1)) }
  )
}

@Suite struct MemoryTests {
  @Test func runtimeAndHostAreReleasedAfterStoppingRunningSagas() async throws {
    weak var weakRuntime: SagaRuntime<Int, Action>?
    weak var weakHost: TestHost<Int, Action>?
    do {
      let host = TestHost<Int, Action>(initialState: 0) { _, _ in }
      let runtime = SagaRuntime(host: host, clock: TestClock())
      host.setRuntime(runtime)
      weakRuntime = runtime
      weakHost = host
      let task = runtime.run(everySaga)
      await runtime.waitUntilIdle()
      runtime.emit(.request(1))
      runtime.emit(.stop)
      await runtime.waitUntilIdle()
      runtime.stop()
      _ = try? await task.join()
      // Host と ランタイムは互いを参照しているので、テストでは循環を切る（SagaMiddleware は Host を弱参照する）。
      host.setRuntime(nil)
    }
    #expect(await eventuallyReleased { weakRuntime == nil })
    #expect(await eventuallyReleased { weakHost == nil })
  }

  @Test func runtimeIsReleasedAfterSagasCompleteWithoutStopping() async throws {
    weak var weakRuntime: SagaRuntime<Int, Action>?
    do {
      let host = TestHost<Int, Action>(initialState: 0) { _, _ in }
      let runtime = SagaRuntime(host: host)
      weakRuntime = runtime
      try await runtime.run(
        Saga { ctx in
          let child = ctx.fork { ctx in await ctx.put(.done(1)) }
          try await ctx.join(child)
        }
      ).join()
    }
    #expect(await eventuallyReleased { weakRuntime == nil })
  }

  @Test func sagaTesterAndEverythingItOwnsAreReleasedAfterFinish() async throws {
    weak var weakTester: SagaTester<Int, Action>?
    weak var weakRuntime: SagaRuntime<Int, Action>?
    do {
      let tester = SagaTester(initialState: 0, reduce: { _, _ in }, saga: everySaga)
      weakTester = tester
      weakRuntime = tester.runtime
      await tester.send(.request(1))
      await tester.send(.stop)
      tester.skipReceivedActions()
      _ = try? await tester.finish()
    }
    #expect(await eventuallyReleased { weakTester == nil })
    #expect(await eventuallyReleased { weakRuntime == nil })
  }
}

/// 解放を確かめるためのオブジェクト。
private final class Payload: Sendable {}

@Suite struct EarlyExitMemoryTests {
  @Test func aChannelClosedAndDroppedIsReleasedBeforeItsCreatorFinishes() async throws {
    let emit = Locked<(@Sendable (Payload) -> Void)?>(nil)
    let channel = Locked<SagaChannel<Payload>?>(nil)
    let tester = SagaTester<Int, Action>(
      initialState: 0, reduce: { _, _ in },
      saga: Saga { ctx in
        do {
          let events = ctx.eventChannel { (send: @escaping @Sendable (Payload) -> Void, _) in
            emit.withLock { $0 = send }
            return {}
          }
          channel.withLock { $0 = events }
        }
        // 作成元の Saga は、チャネルを手放した後も動き続ける（接続と切断を繰り返す長寿命の Saga）。
        _ = try await ctx.take(request)
      })
    await tester.settle()
    weak var weakPayload: Payload?
    do {
      let payload = Payload()
      weakPayload = payload
      emit.withLock { $0 }?(payload)  // 受け取らないまま溜まる
    }
    // 閉じて手放す。
    channel.withLock { $0 }?.close()
    channel.withLock { $0 = nil }
    emit.withLock { $0 = nil }
    #expect(await eventuallyReleased { weakPayload == nil })
    try await tester.finish()
  }

  @Test func releasingASagaTesterWithoutFinishingStopsItsSagas() async {
    weak var weakPayload: Payload?
    do {
      let payload = Payload()
      weakPayload = payload
      let tester = SagaTester<Int, Action>(
        initialState: 0, reduce: { _, _ in },
        saga: Saga { ctx in
          _ = try await ctx.take(request)
          _ = payload
        })
      await tester.settle()
      // 検証が途中で失敗し、finish() に届かないまま手放した。
    }
    #expect(await eventuallyReleased { weakPayload == nil })
  }
}
