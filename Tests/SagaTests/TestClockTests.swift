import InternalPrimitives
import SagaTesting
import Testing

@Suite struct TestClockTests {
  @Test func nowStartsAtZeroAndMovesOnlyWhenAdvanced() {
    let clock = TestClock()
    #expect(clock.now.offset == .zero)
    clock.advance(by: .seconds(3))
    #expect(clock.now.offset == .seconds(3))
  }

  @Test func advanceWakesSleepersWhoseDeadlineHasPassed() async throws {
    let clock = TestClock()
    let woken = Locked<[String]>([])
    async let short: Void = {
      try await clock.sleep(for: .seconds(1))
      woken.withLock { $0.append("short") }
    }()
    async let long: Void = {
      try await clock.sleep(for: .seconds(5))
      woken.withLock { $0.append("long") }
    }()
    while clock.sleeperCount < 2 { await Task.yield() }
    clock.advance(by: .seconds(1))
    try await short
    #expect(woken.withLock { $0 } == ["short"])
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(4))
    try await long
    #expect(woken.withLock { $0 } == ["short", "long"])
  }

  @Test func sleepingUntilAPastDeadlineReturnsImmediately() async throws {
    let clock = TestClock()
    clock.advance(by: .seconds(10))
    try await clock.sleep(until: TestClock.Instant(offset: .seconds(5)))
    #expect(clock.sleeperCount == 0)
  }

  @Test func cancellingASleeperRemovesItAndThrows() async {
    let clock = TestClock()
    let task = Task { try await clock.sleep(for: .seconds(1)) }
    while clock.sleeperCount < 1 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.sleeperCount == 0)
  }

  @Test func advancingToThePastDoesNothing() {
    let clock = TestClock()
    clock.advance(by: .seconds(2))
    clock.advance(to: TestClock.Instant(offset: .seconds(1)))
    #expect(clock.now.offset == .seconds(2))
  }
}
