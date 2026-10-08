import InternalPrimitives

/// 一度だけ発火する合図。fork した子を、外から個別にキャンセルするために使う。
///
/// タスクグループの子タスクは外から個別にキャンセルできないため、子の中で本体とこの合図を競わせ、
/// 合図が先に来たら本体をキャンセルする。
final class CancelSignal: Sendable {
  private struct Storage {
    var isFired = false
    var waiter: CheckedContinuation<Void, Never>?
  }

  private let storage = Locked(Storage())

  func fire() {
    let waiter = storage.withLock { storage -> CheckedContinuation<Void, Never>? in
      storage.isFired = true
      defer { storage.waiter = nil }
      return storage.waiter
    }
    waiter?.resume()
  }

  /// 発火するか、待っているタスクがキャンセルされるまで待つ。受け取り側は 1 つだけであること。
  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let returnsNow = storage.withLock { storage -> Bool in
          guard !storage.isFired, !Task.isCancelled else { return true }
          storage.waiter = continuation
          return false
        }
        if returnsNow { continuation.resume() }
      }
    } onCancel: {
      let waiter = storage.withLock { storage -> CheckedContinuation<Void, Never>? in
        defer { storage.waiter = nil }
        return storage.waiter
      }
      waiter?.resume()
    }
  }
}
