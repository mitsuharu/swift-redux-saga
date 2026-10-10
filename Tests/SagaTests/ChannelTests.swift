import InternalPrimitives
import Testing

@testable import Saga
@testable import SagaTesting

private enum Action: Sendable, Hashable {
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
  @Test(arguments: [false, true])
  func aCancelledConsumerLeavesBufferedValuesForOtherConsumers(closeBeforeCancellation: Bool)
    async throws
  {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request)
        let consumer = ctx.fork { ctx in
          do {
            _ = try await ctx.take(.action(.request(-1)))
          } catch is CancellationError {
            do {
              if let value = try await requests.take() { await ctx.put(.handled(value)) }
            } catch is CancellationError {
              await ctx.put(.event("cancelled"))
            }
          }
        }
        _ = try await ctx.take(.action(.stop))
        if closeBeforeCancellation { requests.close() }
        ctx.cancel(consumer)
        _ = try? await ctx.join(consumer)
        requests.close()
        for try await value in requests { await ctx.put(.handled(value)) }
        await ctx.put(.closed)
      })
    await tester.send(.request(1))
    await tester.send(.request(2))
    await tester.send(.stop)
    #expect(tester.unreceivedActions == [.event("cancelled"), .handled(1), .handled(2), .closed])
    tester.skipReceivedActions()
    try await tester.finish()
  }

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
    let source = Locked<(emit: (@Sendable (String) -> Void)?, finish: EventChannelFinish?)>(
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
    // シーケンスの読み取りは settle の対象外。届かなかった場合もテストを失敗として終えられるようにする。
    try await tester.receive(.event("x"), timeout: .seconds(5))
    try await tester.receive(.closed, timeout: .seconds(5))
    try await tester.finish()
  }
}

private struct Disconnected: Error {}

@Suite struct EventChannelErrorTests {
  @Test func aCancelledConsumerDoesNotConsumeTheChannelFailure() async throws {
    let tester = makeTester(
      Saga { ctx in
        let events = ctx.eventChannel { (_: @escaping @Sendable (String) -> Void, finish) in
          finish(throwing: Disconnected())
          return {}
        }
        let consumer = ctx.fork { ctx in
          do {
            _ = try await ctx.take(.action(.request(-1)))
          } catch is CancellationError {
            do {
              _ = try await events.take()
            } catch is CancellationError {
              await ctx.put(.event("cancelled"))
            } catch {
              await ctx.put(.event("unexpected failure"))
            }
          }
        }
        _ = try await ctx.take(.action(.stop))
        ctx.cancel(consumer)
        _ = try? await ctx.join(consumer)
        do {
          _ = try await events.take()
        } catch is Disconnected {
          await ctx.put(.closed)
        }
      })
    await tester.send(.stop)
    #expect(tester.unreceivedActions == [.event("cancelled"), .closed])
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func anAsyncSequenceThatEndsWithAnErrorThrowsItAfterTheBufferedValues() async throws {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
    let tester = makeTester(
      Saga { ctx in
        do {
          for try await event in ctx.eventChannel(from: stream) {
            await ctx.put(.event(event))
          }
          await ctx.put(.closed)
        } catch is Disconnected {
          await ctx.put(.event("disconnected"))
        }
      })
    continuation.yield("x")
    continuation.finish(throwing: Disconnected())
    // シーケンスの読み取りは settle の対象外。届かなかった場合もテストを失敗として終えられるようにする。
    try await tester.receive(.event("x"), timeout: .seconds(5))
    try await tester.receive(.event("disconnected"), timeout: .seconds(5))
    try await tester.finish()
  }

  @Test func anAsyncSequenceThatEndsWithCancellationErrorEndsTheChannel() async throws {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
    let tester = makeTester(
      Saga { ctx in
        do {
          for try await event in ctx.eventChannel(from: stream) {
            await ctx.put(.event(event))
          }
        } catch is CancellationError {
          // 入力元が CancellationError で終わった（この Saga はキャンセルされていない）。
          await ctx.put(.closed)
        }
      })
    continuation.yield("x")
    continuation.finish(throwing: CancellationError())
    // シーケンスの読み取りは Saga ではないので settle の対象外。届くまで待つ。
    try await tester.receive(.event("x"), timeout: .seconds(5))
    try await tester.receive(.closed, timeout: .seconds(5))
    try await tester.finish()
  }

  @Test func finishingWithAnErrorThrowsItToTheWaitingTaker() async throws {
    let finish = Locked<EventChannelFinish?>(nil)
    let tester = makeTester(
      Saga { ctx in
        let events = ctx.eventChannel { (_: @escaping @Sendable (String) -> Void, end) in
          finish.withLock { $0 = end }
          return {}
        }
        do {
          for try await _ in events {}
          await ctx.put(.closed)
        } catch is Disconnected {
          await ctx.put(.event("disconnected"))
        }
      })
    await tester.settle()
    finish.withLock { $0 }?(throwing: Disconnected())
    await tester.settle()
    try tester.receive(.event("disconnected"))
    try await tester.finish()
  }
}

@Suite struct ChannelWorkerPoolTests {
  @Test func severalSagasCanShareOneChannelAndEachValueGoesToOneOfThem() async throws {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request)
        // 3 つのワーカーで 1 つのチャネルを読む（ワーカープール）。
        for worker in 1...3 {
          ctx.fork { ctx in
            for try await id in requests {
              try await ctx.delay(.seconds(1))
              await ctx.put(.handled(id * 10 + worker))
            }
          }
        }
      })
    for id in 1...4 {
      await tester.send(.request(id))
    }
    await tester.advance(by: .seconds(1))
    // 最初の 3 件を 3 つのワーカーが 1 件ずつ並行に処理する（どのワーカーがどれを取るかは待ち始めた順）。
    let handled = tester.unreceivedActions.compactMap { action -> Int? in
      if case .handled(let value) = action { value } else { nil }
    }
    #expect(Set(handled.map { $0 / 10 }) == [1, 2, 3])
    #expect(Set(handled.map { $0 % 10 }) == [1, 2, 3])
    tester.skipReceivedActions()
    await tester.advance(by: .seconds(1))
    #expect(tester.unreceivedActions.count == 1)
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func cancellingOneWaitingSagaDoesNotRemoveTheOthers() async throws {
    let tester = makeTester(
      Saga { ctx in
        let requests = ctx.actionChannel(request)
        let first = ctx.fork { _ in _ = try await requests.take() }
        ctx.fork { ctx in
          if let id = try await requests.take() { await ctx.put(.handled(id)) }
        }
        _ = try await ctx.take(.action(.stop))
        ctx.cancel(first)
        _ = try await ctx.take(.action(.closed))
      })
    await tester.send(.stop)
    await tester.send(.request(5))
    try tester.receive(.handled(5))
    await tester.send(.closed)
    try await tester.finish()
  }
}
