import InternalPrimitives

/// Saga のスコープに、子の起動要求を渡すキュー。
///
/// `AsyncStream` を使わないのは、受け取り側のタスクがキャンセルされると iteration が終わり、
/// 積まれた要求が起動されないまま残る（join している側が永久に待つ）ため。
/// このキューはキャンセルされても閉じられるまで要求を渡し続ける。起動された子はキャンセル済みの
/// タスクグループの中で動くので、すぐにキャンセルとして終わる。
final class ForkQueue<Element: Sendable>: Sendable {
  private struct Storage {
    var buffer: [Element] = []
    var waiter: CheckedContinuation<Element?, Never>?
    var isClosed = false
  }

  private let storage = Locked(Storage())

  /// 要求を積む。閉じられていれば積まずに `false` を返す。
  func push(_ element: Element) -> Bool {
    let result = storage.withLock {
      storage -> (accepted: Bool, waiter: CheckedContinuation<Element?, Never>?) in
      guard !storage.isClosed else { return (false, nil) }
      if let waiter = storage.waiter {
        storage.waiter = nil
        return (true, waiter)
      }
      storage.buffer.append(element)
      return (true, nil)
    }
    result.waiter?.resume(returning: element)
    return result.accepted
  }

  /// 次の要求を待つ。閉じられて空になったら `nil` を返す。受け取り側は 1 つだけであること。
  func next() async -> Element? {
    await withCheckedContinuation { continuation in
      let immediate = storage.withLock { storage -> Element?? in
        if !storage.buffer.isEmpty { return .some(storage.buffer.removeFirst()) }
        if storage.isClosed { return .some(nil) }
        storage.waiter = continuation
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }

  /// これ以上の要求を受け付けない。積まれている要求は `next()` で受け取れる。
  func close() {
    let waiter = storage.withLock { storage -> CheckedContinuation<Element?, Never>? in
      storage.isClosed = true
      guard storage.buffer.isEmpty else { return nil }
      defer { storage.waiter = nil }
      return storage.waiter
    }
    waiter?.resume(returning: nil)
  }
}
