import Saga
import SagaTesting
import Testing

private enum Action: Sendable, Equatable {
  case input(String)
  case search(String)
  case scroll(Int)
  case handled(Int)
}

private let input = ActionPattern<Action, String>.case {
  if case .input(let text) = $0 { text } else { nil }
}

private let scroll = ActionPattern<Action, Int>.case {
  if case .scroll(let offset) = $0 { offset } else { nil }
}

private func makeTester(_ saga: Saga<Int, Action>) -> SagaTester<Int, Action> {
  SagaTester(initialState: 0, reduce: { _, _ in }, saga: saga)
}

@Suite struct DebounceThrottleTests {
  @Test func debounceRunsTheWorkerOnceWithTheLastActionAfterTheQuietPeriod() async throws {
    let tester = makeTester(
      Saga { ctx in
        ctx.debounce(.milliseconds(300), input) { ctx, text in await ctx.put(.search(text)) }
      })
    await tester.send(.input("s"))
    await tester.advance(by: .milliseconds(200))
    await tester.send(.input("sw"))
    await tester.advance(by: .milliseconds(200))
    await tester.send(.input("swift"))
    await tester.advance(by: .milliseconds(299))
    #expect(tester.unreceivedActions.isEmpty)
    await tester.advance(by: .milliseconds(1))
    try tester.receive(.search("swift"))
    try await tester.finish()
  }

  @Test func debounceDoesNotCancelAWorkerThatHasAlreadyStarted() async throws {
    let tester = makeTester(
      Saga { ctx in
        ctx.debounce(.milliseconds(100), input) { ctx, text in
          try await ctx.delay(.seconds(1))
          await ctx.put(.search(text))
        }
      })
    await tester.send(.input("a"))
    await tester.advance(by: .milliseconds(100))  // ワーカーが動き出す
    await tester.send(.input("b"))
    await tester.advance(by: .seconds(2))
    #expect(tester.unreceivedActions == [.search("a"), .search("b")])
    tester.skipReceivedActions()
    try await tester.finish()
  }

  @Test func throttleRunsTheFirstActionAndKeepsOnlyTheLastOneDuringThePeriod() async throws {
    let tester = makeTester(
      Saga { ctx in
        ctx.throttle(.seconds(1), scroll) { ctx, offset in await ctx.put(.handled(offset)) }
      })
    await tester.send(.scroll(1))
    try tester.receive(.handled(1))
    await tester.send(.scroll(2))
    await tester.send(.scroll(3))
    await tester.send(.scroll(4))
    #expect(tester.unreceivedActions.isEmpty)
    await tester.advance(by: .seconds(1))
    try tester.receive(.handled(4))
    await tester.advance(by: .seconds(1))
    #expect(tester.unreceivedActions.isEmpty)
    await tester.send(.scroll(5))
    try tester.receive(.handled(5))
    try await tester.finish()
  }

  @Test func cancellingADebounceDropsThePendingAction() async throws {
    let clock = TestClock()
    let tester = SagaTester<Int, Action>(
      initialState: 0, reduce: { _, _ in },
      saga: Saga { ctx in
        let helper = ctx.debounce(.seconds(1), input) { ctx, text in
          await ctx.put(.search(text))
        }
        _ = try await ctx.take(.action(.scroll(0)))
        ctx.cancel(helper)
      },
      clock: clock)
    await tester.send(.input("a"))
    await tester.send(.scroll(0))
    #expect(clock.sleeperCount == 0)
    await tester.advance(by: .seconds(1))
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }
}
