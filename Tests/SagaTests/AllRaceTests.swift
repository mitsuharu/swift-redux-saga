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

  @Test func allLetsTheCallerCatchAFailureOfAChildForkedInsideAnOperation() async throws {
    let tester = makeTester(
      Saga { ctx in
        do {
          let _: (Void, Void) = try await ctx.all(
            { ctx in ctx.fork { _ in throw TestError() } },
            { ctx in try await ctx.delay(.seconds(10)) }
          )
        } catch is TestError {
          await ctx.put(.failed)
        }
      })
    await tester.settle()
    try tester.receive(.failed)
    #expect(tester.errors.isEmpty)
    try await tester.finish()
  }

  @Test func raceLetsTheCallerCatchAFailureOfAChildForkedInsideTheWinner() async throws {
    let tester = makeTester(
      Saga { ctx in
        do {
          _ = try await ctx.race(
            { ctx in ctx.fork { _ in throw TestError() } },
            { ctx in try await ctx.take(response) }
          )
        } catch is TestError {
          await ctx.put(.failed)
        }
      })
    await tester.settle()
    try tester.receive(.failed)
    #expect(tester.errors.isEmpty)
    try await tester.finish()
  }

  @Test func raceThrowsCancellationWhenTheWinnerEndsByCancellation() async throws {
    let tester = makeTester(
      Saga { ctx in
        do {
          let _: (Int?, Int?) = try await ctx.race(
            { _ -> Int in throw CancellationError() },
            { ctx in
              try await ctx.delay(.seconds(10))
              return 2
            }
          )
          await ctx.put(.result("winner"))
        } catch is CancellationError {
          await ctx.put(.result("cancelled"))
        }
      })
    await tester.settle()
    try tester.receive(.result("cancelled"))
    try await tester.finish()
  }

  @Test func allThrowsCancellationAndCancelsTheOthersWhenAnOperationEndsByCancellation()
    async throws
  {
    let tester = makeTester(
      Saga { ctx in
        do {
          let _: (Void, String) = try await ctx.all(
            { _ in throw CancellationError() },
            { ctx in try await ctx.take(response) }
          )
          await ctx.put(.result("completed"))
        } catch is CancellationError {
          await ctx.put(.result("cancelled"))
        }
      })
    await tester.settle()
    try tester.receive(.result("cancelled"))
    try await tester.finish()
  }

  @Test func allThrowsCancellationInACancelledCallerEvenIfTheOperationsReturnValues() async throws {
    let tester = makeTester(
      Saga { ctx in
        let worker = ctx.fork { ctx in
          do {
            _ = try await ctx.take(response)
          } catch is CancellationError {
            do {
              // キャンセルに応じずに値を返す処理
              let (a, b) = try await ctx.all({ _ in "a" }, { _ in "b" })
              await ctx.put(.result(a + b))
            } catch is CancellationError {
              await ctx.put(.result("cancelled"))
            }
          }
        }
        _ = try await ctx.take(.action(.start))
        ctx.cancel(worker)
        _ = try? await ctx.join(worker)
      })
    await tester.send(.start)
    try tester.receive(.result("cancelled"))
    try await tester.finish()
  }

  @Test func allThrowsCancellationInsteadOfAFailureInACancelledCaller() async throws {
    let tester = makeTester(
      Saga { ctx in
        let worker = ctx.fork { ctx in
          do {
            _ = try await ctx.take(response)
          } catch is CancellationError {
            do {
              _ = try await ctx.all({ _ -> Int in throw TestError() }, { _ in 1 })
              await ctx.put(.result("returned"))
            } catch is CancellationError {
              await ctx.put(.result("cancelled"))
            } catch {
              await ctx.put(.failed)
            }
          }
        }
        _ = try await ctx.take(.action(.start))
        ctx.cancel(worker)
        _ = try? await ctx.join(worker)
      })
    await tester.send(.start)
    try tester.receive(.result("cancelled"))
    try await tester.finish()
  }

  @Test func raceThrowsCancellationInACancelledCallerEvenIfTheWinnerReturnsAValue() async throws {
    let tester = makeTester(
      Saga { ctx in
        let worker = ctx.fork { ctx in
          do {
            _ = try await ctx.take(response)
          } catch is CancellationError {
            do {
              let (a, _) = try await ctx.race({ _ in "a" }, { ctx in try await ctx.take(response) })
              await ctx.put(.result(a ?? "nil"))
            } catch is CancellationError {
              await ctx.put(.result("cancelled"))
            }
          }
        }
        _ = try await ctx.take(.action(.start))
        ctx.cancel(worker)
        _ = try? await ctx.join(worker)
      })
    await tester.send(.start)
    try tester.receive(.result("cancelled"))
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
