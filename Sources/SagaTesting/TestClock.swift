import InternalPrimitives
import Saga

/// 手動で進める時計。
///
/// 実時間では進まず、``advance(by:)`` を呼んだときだけ進みます。`delay` / `debounce` / `throttle` を
/// 使う Saga を、実時間に依存せずにテストするために使います。
///
/// ```swift
/// let clock = TestClock()
/// let tester = SagaTester(initialState: AppState(), reduce: reduce, saga: saga, clock: clock)
/// await tester.advance(by: .seconds(1))
/// ```
public final class TestClock: Clock, Sendable {
  /// ``TestClock`` の時刻。作った時点からの経過時間で表します。
  public struct Instant: InstantProtocol, Sendable {
    /// 時計を作った時点からの経過時間。
    public var offset: Duration

    public init(offset: Duration = .zero) {
      self.offset = offset
    }

    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private struct Sleeper {
    let deadline: Instant
    let order: Int
    let continuation: CheckedContinuation<Void, any Error>
    let onWake: (@Sendable () -> Void)?
  }

  private struct Storage {
    var now = Instant()
    var nextID = 0
    var sleepers: [Int: Sleeper] = [:]
  }

  private let storage = Locked(Storage())

  public init() {}

  public var now: Instant {
    storage.withLock { $0.now }
  }

  public var minimumResolution: Duration {
    .zero
  }

  /// 眠っているタスクの数。
  public var sleeperCount: Int {
    storage.withLock { $0.sleepers.count }
  }

  /// 眠っているタスクのうち、最も早い起床時刻。
  public var nextDeadline: Instant? {
    storage.withLock { $0.sleepers.values.map(\.deadline).min() }
  }

  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    try await sleep(until: deadline, onWake: nil)
  }

  /// 時計を進め、起床時刻を過ぎたタスクを起こします。
  ///
  /// 起こすのは呼び出した時点で眠っているタスクだけです。起きたタスクがさらに眠る場合、その起床時刻が
  /// 進めた範囲に入っていても起きません。続けて起こすには `SagaTester.advance(by:)` を使ってください。
  public func advance(by duration: Duration) {
    advance(to: now.advanced(by: duration))
  }

  /// 時計を進め、進めた範囲で起きるタスクを起床時刻の順に起こします。起こすたびに `settle` で待ちます。
  ///
  /// 起きたタスクがさらに眠り、その起床時刻が進めた範囲に入っている場合も起こします。
  /// `SagaTester` / `TestStore` の `advance(by:)` はこのメソッドを使います。
  ///
  /// - Parameters:
  ///   - duration: 進める時間。
  ///   - settle: 起きたタスクが止まるまで待つ関数（`SagaTester.settle()` など）。
  nonisolated(nonsending) public func advance(
    by duration: Duration, settlingWith settle: () async -> Void
  ) async {
    await settle()
    let target = now.advanced(by: duration)
    while let next = nextDeadline, next <= target {
      advance(to: next)
      await settle()
    }
    advance(to: target)
    await settle()
  }

  /// 指定した時刻まで時計を進め、起床時刻を過ぎたタスクを起こします。過去の時刻を渡した場合は進めません。
  public func advance(to instant: Instant) {
    let woken = storage.withLock { storage -> [Sleeper] in
      guard storage.now < instant else { return [] }
      storage.now = instant
      let due = storage.sleepers.filter { $0.value.deadline <= instant }
      for id in due.keys {
        storage.sleepers[id] = nil
      }
      return due.values.sorted { ($0.deadline, $0.order) < ($1.deadline, $1.order) }
    }
    for sleeper in woken {
      sleeper.onWake?()
      sleeper.continuation.resume()
    }
  }

  private func sleep(until deadline: Instant, onWake: (@Sendable () -> Void)?) async throws {
    let id = storage.withLock { storage in
      defer { storage.nextID += 1 }
      return storage.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        enum Outcome { case slept, due, cancelled }
        let outcome = storage.withLock { storage -> Outcome in
          guard !Task.isCancelled else { return .cancelled }
          guard storage.now < deadline else { return .due }
          storage.sleepers[id] = Sleeper(
            deadline: deadline, order: id, continuation: continuation, onWake: onWake)
          return .slept
        }
        switch outcome {
        case .slept:
          break
        case .due:
          onWake?()
          continuation.resume()
        case .cancelled:
          onWake?()
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      guard let sleeper = storage.withLock({ $0.sleepers.removeValue(forKey: id) }) else { return }
      sleeper.onWake?()
      sleeper.continuation.resume(throwing: CancellationError())
    }
  }
}

extension TestClock: ActivityTrackingClock {
  package func sleep(for duration: Duration, onWake: @escaping @Sendable () -> Void) async throws {
    try await sleep(until: now.advanced(by: duration), onWake: onWake)
  }
}
