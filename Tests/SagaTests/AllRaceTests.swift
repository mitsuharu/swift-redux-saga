import Saga
import SagaTesting
import Testing

private enum Action: Sendable, Equatable {
  case start
  case response(String)
  case result(String)
  case failed
  case timedOut
}

private struct TestError: Error {}

private func makeTester(_ saga: Saga<Int, Action>, clock: TestClock = TestClock())
  -> SagaTester<Int, Action>
{
  SagaTester(initialState: 0, reduce: { _, _ in }, saga: saga, clock: clock)
}

private let response = ActionPattern<Action, String>.case {
  if case .response(let text) = $0 { text } else { nil }
}

@Suite struct AllRaceTests {
  @Test func allReturnsEveryResultAfterTheSlowestOperation() async throws {
    let tester = makeTester(
      Saga { ctx in
        let (a, b, c) = try await ctx.all(
          { ctx in
            try await ctx.delay(.seconds(2))
            return "a"
          },
          { _ in 1 },
          { ctx in
            try await ctx.delay(.seconds(1))
            return true
          }
        )
        await ctx.put(.result("\(a) \(b) \(c)"))
      })
    await tester.advance(by: .seconds(1))
    #expect(tester.unreceivedActions.isEmpty)
    await tester.advance(by: .seconds(1))
    try tester.receive(.result("a 1 true"))
    try await tester.finish()
  }

  @Test func allThrowsTheFirstFailureAndCancelsTheOtherOperations() async throws {
    let clock = TestClock()
    let tester = makeTester(
      Saga { ctx in
        do {
          _ = try await ctx.all(
            { ctx in try await ctx.delay(.seconds(10)) },
            { ctx in
              try await ctx.delay(.seconds(1))
              throw TestError()
            }
          )
        } catch is TestError {
          await ctx.put(.failed)
        }
      },
      clock: clock)
    await tester.advance(by: .seconds(1))
    try tester.receive(.failed)
    #expect(clock.sleeperCount == 0)
    #expect(!tester.isRunning)
    try await tester.finish()
  }

  @Test func raceReturnsOnlyTheWinnerAndCancelsTheLosers() async throws {
    let clock = TestClock()
    let tester = makeTester(
      Saga { ctx in
        let (text, timeout): (String?, Void?) = try await ctx.race(
          { ctx in try await ctx.take(response) },
          { ctx in try await ctx.delay(.seconds(5)) }
        )
        if let text { await ctx.put(.result(text)) }
        if timeout != nil { await ctx.put(.timedOut) }
      },
      clock: clock)
    await tester.send(.response("ok"))
    try tester.receive(.result("ok"))
    #expect(clock.sleeperCount == 0)
    try await tester.finish()
  }

  @Test func raceReportsATimeoutWhenTheDelayWins() async throws {
    let tester = makeTester(
      Saga { ctx in
        let (text, timeout): (String?, Void?) = try await ctx.race(
          { ctx in try await ctx.take(response) },
          { ctx in try await ctx.delay(.seconds(5)) }
        )
        if let text { await ctx.put(.result(text)) }
        if timeout != nil { await ctx.put(.timedOut) }
      })
    await tester.advance(by: .seconds(5))
    try tester.receive(.timedOut)
    await tester.send(.response("late"))
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }

  @Test func raceThrowsWhenTheWinnerFails() async throws {
    let tester = makeTester(
      Saga { ctx in
        do {
          _ = try await ctx.race(
            { _ in throw TestError() },
            { ctx in try await ctx.take(response) }
          )
        } catch is TestError {
          await ctx.put(.failed)
        }
      })
    await tester.settle()
    try tester.receive(.failed)
    try await tester.finish()
  }

  @Test func cancellingTheCallerCancelsEveryOperation() async throws {
    let clock = TestClock()
    let tester = makeTester(
      Saga { ctx in
        let worker = ctx.fork { ctx in
          _ = try await ctx.all(
            { ctx in try await ctx.delay(.seconds(1)) },
            { ctx in try await ctx.take(response) }
          )
          await ctx.put(.result("finished"))
        }
        _ = try await ctx.take(.action(.start))
        ctx.cancel(worker)
      },
      clock: clock)
    await tester.settle()
    #expect(clock.sleeperCount == 1)
    await tester.send(.start)
    #expect(clock.sleeperCount == 0)
    await tester.send(.response("ignored"))
    await tester.advance(by: .seconds(1))
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }
}
