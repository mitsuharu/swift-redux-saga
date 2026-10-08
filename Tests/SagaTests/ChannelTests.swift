import InternalPrimitives
import Testing

@testable import Saga
@testable import SagaTesting

private enum Action: Sendable, Equatable {
  case request(Int)
  case handled(Int)
  case event(String)
  case closed
  case stop
}

private let request = ActionPattern<Action, Int>.case {
  if case .request(let id) = $0 { id } else { nil }
}

private func makeTester(_ saga: Saga<Int, Action>) -> SagaTester<Int, Action> {
  SagaTester(initialState: 0, reduce: { _, _ in }, saga: saga)
}

@Suite struct ChannelTests {
  @Test func actionChannelQueuesActionsSoTheyAreHandledOneByOneInOrder() async throws {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request)
        for try await id in requests {
          try await ctx.delay(.seconds(1))
          await ctx.put(.handled(id))
        }
      })
    await tester.send(.request(1))
    await tester.send(.request(2))
    await tester.send(.request(3))
    await tester.advance(by: .seconds(1))
    try tester.receive(.handled(1))
    await tester.advance(by: .seconds(2))
    try tester.receive(.handled(2))
    try tester.receive(.handled(3))
    try await tester.finish()
  }

  @Test func actionChannelWithANewestBufferKeepsOnlyTheLatestActions() async throws {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request, buffer: .newest(1))
        _ = try await ctx.take(.action(.stop))
        while let id = try await requests.take() {
          await ctx.put(.handled(id))
        }
      })
    await tester.send(.request(1))
    await tester.send(.request(2))
    await tester.send(.stop)
    try tester.receive(.handled(2))
    try await tester.finish()
  }

  @Test func actionChannelWithAnOldestBufferKeepsOnlyTheFirstActions() async throws {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request, buffer: .oldest(2))
        _ = try await ctx.take(.action(.stop))
        requests.close()
        while let id = try await requests.take() {
          await ctx.put(.handled(id))
        }
        await ctx.put(.closed)
      })
    for id in 1...4 {
      await tester.send(.request(id))
    }
    await tester.send(.stop)
    #expect(tester.unreceivedActions == [.handled(1), .handled(2), .closed])
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func actionChannelStopsListeningWhenTheSagaThatCreatedItFinishes() async throws {
    let tester = makeTester(
      Saga { ctx in
        _ = ctx.actionChannel(request)
      })
    await tester.settle()
    #expect(tester.runtime.multicaster.subscriberCount == 0)
    try await tester.finish()
  }

  @Test func eventChannelDeliversEmittedValuesAndEndsWhenTheSourceFinishes() async throws {
    let source = Locked<(emit: (@Sendable (String) -> Void)?, finish: (@Sendable () -> Void)?)>(
      (nil, nil))
    let unsubscribed = Locked(false)
    let tester = makeTester(
      Saga { ctx in
        let events = ctx.eventChannel { (emit: @escaping @Sendable (String) -> Void, finish) in
          source.withLock { $0 = (emit, finish) }
          return { unsubscribed.withLock { $0 = true } }
        }
        for try await event in events {
          await ctx.put(.event(event))
        }
        await ctx.put(.closed)
      })
    await tester.settle()
    source.withLock { $0 }.emit?("a")
    source.withLock { $0 }.emit?("b")
    await tester.settle()
    try tester.receive(.event("a"))
    try tester.receive(.event("b"))
    source.withLock { $0 }.finish?()
    await tester.settle()
    try tester.receive(.closed)
    #expect(unsubscribed.withLock { $0 })
    try await tester.finish()
  }

  @Test func eventChannelUnsubscribesWhenTheSagaIsCancelled() async throws {
    let unsubscribed = Locked(false)
    let tester = makeTester(
      Saga { ctx in
        let worker = ctx.fork { ctx in
          let events = ctx.eventChannel { (_: @escaping @Sendable (String) -> Void, _) in
            { unsubscribed.withLock { $0 = true } }
          }
          for try await _ in events {}
        }
        _ = try await ctx.take(.action(.stop))
        ctx.cancel(worker)
      })
    await tester.send(.stop)
    #expect(unsubscribed.withLock { $0 })
    try await tester.finish()
  }

  @Test func eventChannelReadsAnAsyncSequence() async throws {
    let (stream, continuation) = AsyncStream.makeStream(of: String.self)
    let tester = makeTester(
      Saga { ctx in
        for try await event in ctx.eventChannel(from: stream) {
          await ctx.put(.event(event))
        }
        await ctx.put(.closed)
      })
    continuation.yield("x")
    continuation.finish()
    // シーケンスの読み取りは Saga ではないので settle の対象外。届くまで待つ。
    while tester.unreceivedActions.count < 2 {
      await tester.settle()
      await Task.yield()
    }
    try tester.receive(.event("x"))
    try tester.receive(.closed)
    try await tester.finish()
  }
}
