import InternalPrimitives

/// チャネルのバッファの方式。
public enum ChannelBuffer: Sendable {
  /// 上限なしで溜める。
  case unbounded
  /// 最新の `n` 個だけを溜める（古いものを捨てる）。
  case newest(Int)
  /// 最初の `n` 個だけを溜める（新しいものを捨てる）。
  case oldest(Int)
}

/// 値を溜めて、受け取り側に順に渡すチャネルの中身。
///
/// 受け取り側は複数でもよい。複数の Saga が待っている場合は、待ち始めた順に 1 つずつ渡す
/// （redux-saga のワーカープールのように、1 つのチャネルを複数のワーカーで読める）。
///
/// `AsyncStream` を使わないのは、受け取り側の再開を Activity で数える必要があるため
/// （値を渡す側が resume の直前に数える。`Activity` を参照）。
final class ChannelCore<Value: Sendable>: Sendable {
  private struct Storage {
    var buffer: [Value] = []
    var nextTakerID = 0
    /// 待っている受け取り側。待ち始めた順。
    var takers: [(id: Int, continuation: CheckedContinuation<Value?, any Error>)] = []
    var isClosed = false
    var onClose: (@Sendable () -> Void)?
  }

  private enum TakeOutcome {
    case value(Value?)
    case waiting
    case cancelled
  }

  private let storage = Locked(Storage())
  private let policy: ChannelBuffer
  private let activity: Activity

  init(buffer policy: ChannelBuffer, activity: Activity) {
    self.policy = policy
    self.activity = activity
  }

  /// 閉じたときに呼ぶ処理を登録する（購読の解除など）。すでに閉じていれば、その場で呼ぶ。
  func onClose(_ handler: @escaping @Sendable () -> Void) {
    let isClosed = storage.withLock { storage -> Bool in
      if storage.isClosed { return true }
      storage.onClose = handler
      return false
    }
    if isClosed { handler() }
  }

  /// 値を入れる。待っている受け取り側がいれば直接渡し、いなければバッファの方式に従って溜める。
  func put(_ value: Value) {
    let taker = storage.withLock { [policy] storage -> CheckedContinuation<Value?, any Error>? in
      guard !storage.isClosed else { return nil }
      if !storage.takers.isEmpty {
        return storage.takers.removeFirst().continuation
      }
      switch policy {
      case .unbounded:
        storage.buffer.append(value)
      case .newest(let limit):
        storage.buffer.append(value)
        if storage.buffer.count > max(limit, 0) { storage.buffer.removeFirst() }
      case .oldest(let limit):
        if storage.buffer.count < limit { storage.buffer.append(value) }
      }
      return nil
    }
    if let taker {
      activity.begin()
      taker.resume(returning: value)
    }
  }

  /// 次の値を待つ。閉じられて空になったら `nil` を返す。
  func take() async throws -> Value? {
    let id = storage.withLock { storage in
      defer { storage.nextTakerID += 1 }
      return storage.nextTakerID
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let outcome = storage.withLock { storage -> TakeOutcome in
          if !storage.buffer.isEmpty { return .value(storage.buffer.removeFirst()) }
          if storage.isClosed { return .value(nil) }
          guard !Task.isCancelled else { return .cancelled }
          storage.takers.append((id, continuation))
          return .waiting
        }
        switch outcome {
        case .value(let value): continuation.resume(returning: value)
        case .waiting: activity.end()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      // ほかの受け取り側を外さないよう、自分の ID の待機だけを外す。
      let taker = storage.withLock { storage -> CheckedContinuation<Value?, any Error>? in
        guard let index = storage.takers.firstIndex(where: { $0.id == id }) else { return nil }
        return storage.takers.remove(at: index).continuation
      }
      if let taker {
        activity.begin()
        taker.resume(throwing: CancellationError())
      }
    }
  }

  /// チャネルを閉じる。溜まっている値は受け取れる。待っている受け取り側には `nil` を渡す。
  func close() {
    let (takers, onClose) = storage.withLock {
      storage -> ([CheckedContinuation<Value?, any Error>], (@Sendable () -> Void)?) in
      guard !storage.isClosed else { return ([], nil) }
      storage.isClosed = true
      // 受け取り側が待っているのはバッファが空のときだけなので、待っている全員に nil を渡してよい。
      defer {
        storage.takers = []
        storage.onClose = nil
      }
      return (storage.takers.map(\.continuation), storage.onClose)
    }
    onClose?()
    for taker in takers {
      activity.begin()
      taker.resume(returning: nil)
    }
  }
}
