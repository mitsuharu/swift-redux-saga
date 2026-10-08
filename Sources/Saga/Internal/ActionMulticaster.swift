import InternalPrimitives

/// emit された Action を、その時点で待っている `take` と購読者に配る。
///
/// ランタイムのインスタンスが 1 つずつ所有する（旧実装の `Bridge.shared` のようなグローバルな配信は持たない）。
final class ActionMulticaster<Action: Sendable>: Sendable {
  private struct Taker {
    /// 一致したら resume する関数を返し、一致しなければ nil を返す。
    let match: @Sendable (Action) -> (@Sendable () -> Void)?
    let cancel: @Sendable () -> Void
  }

  private struct Storage {
    var nextID = 0
    var takers: [Int: Taker] = [:]
    var subscribers: [Int: @Sendable (Action) -> Void] = [:]
  }

  private let storage = Locked(Storage())
  private let activity: Activity

  init(activity: Activity) {
    self.activity = activity
  }

  private func makeID() -> Int {
    storage.withLock { storage in
      defer { storage.nextID += 1 }
      return storage.nextID
    }
  }

  /// 次に emit される、パターンに一致する Action を待つ。
  ///
  /// 一致した時点で登録を外す（1 回限り）。キャンセルされたら登録を外して `CancellationError` を投げる。
  func take<Value>(_ pattern: ActionPattern<Action, Value>) async throws -> Value {
    let id = makeID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let taker = Taker(
          match: { action in
            guard let value = pattern.match(action) else { return nil }
            return { continuation.resume(returning: value) }
          },
          cancel: { continuation.resume(throwing: CancellationError()) }
        )
        let registered = storage.withLock { storage -> Bool in
          // キャンセルの確認をロックの中で行うのは、onCancel が登録より先に走った場合に取り残されないため。
          guard !Task.isCancelled else { return false }
          storage.takers[id] = taker
          return true
        }
        if registered {
          activity.end()
        } else {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      guard let taker = storage.withLock({ $0.takers.removeValue(forKey: id) }) else { return }
      activity.begin()
      taker.cancel()
    }
  }

  /// emit されるすべての Action を受け取る購読者を登録する。戻り値の関数で登録を外す。
  func subscribe(_ receive: @escaping @Sendable (Action) -> Void) -> @Sendable () -> Void {
    let id = makeID()
    storage.withLock { $0.subscribers[id] = receive }
    return { [storage] in
      _ = storage.withLock { $0.subscribers.removeValue(forKey: id) }
    }
  }

  /// 待っている take の数（テスト用）。
  var takerCount: Int {
    storage.withLock { $0.takers.count }
  }

  /// Action を配る。
  func emit(_ action: Action) {
    let (resumes, subscribers) = storage.withLock {
      storage -> ([@Sendable () -> Void], [@Sendable (Action) -> Void]) in
      var resumes: [@Sendable () -> Void] = []
      for (id, taker) in storage.takers {
        if let resume = taker.match(action) {
          resumes.append(resume)
          storage.takers[id] = nil
        }
      }
      return (resumes, Array(storage.subscribers.values))
    }
    // resume と購読者の呼び出しをロックの外で行うのは、呼び出し先から再び emit されてもデッドロックしないため。
    for resume in resumes {
      activity.begin()
      resume()
    }
    for subscriber in subscribers {
      subscriber(action)
    }
  }
}
