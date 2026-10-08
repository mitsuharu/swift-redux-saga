import InternalPrimitives
import Testing

@Suite struct LockedTests {
  @Test func withLockReturnsTheResultOfTheBody() {
    let locked = Locked([1, 2, 3])
    #expect(locked.withLock { $0.count } == 3)
  }

  @Test func mutationsAreVisibleThroughCopiesOfTheSameLock() {
    let locked = Locked(0)
    let copy = locked
    copy.withLock { $0 = 42 }
    #expect(locked.withLock { $0 } == 42)
  }

  @Test func concurrentIncrementsAreNotLost() async {
    let locked = Locked(0)
    await withDiscardingTaskGroup { group in
      for _ in 0..<1_000 {
        group.addTask {
          locked.withLock { $0 += 1 }
        }
      }
    }
    #expect(locked.withLock { $0 } == 1_000)
  }
}
