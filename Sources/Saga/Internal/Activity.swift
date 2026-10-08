import InternalPrimitives

/// 実行中（Effect で止まっていない）の Saga の数を数える。
///
/// テスト支援（`SagaTesting`）が「すべての Saga が Effect で止まるまで待つ」ために使う。
/// 実時間や `Task.yield()` の回数に頼らずにテストを書けるようにするため。
///
/// 数え方:
/// - Saga の起動を要求した時点（タスクが実際に動き出す前）に `begin()`、終わったら `end()`。
/// - `take` などで止まる直前に `end()`、止まった Saga を再開させる側が resume の直前に `begin()`。
///   再開される側ではなく再開させる側で数えるのは、resume から実際に動き出すまでの間に
///   「全員止まっている」と誤判定しないため。
package final class Activity: Sendable {
  private struct Storage {
    var running = 0
    var nextWaiterID = 0
    var idleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  }

  private let storage = Locked(Storage())

  package init() {}

  /// 実行中の Saga の数。
  package var running: Int {
    storage.withLock { $0.running }
  }

  package func begin() {
    storage.withLock { $0.running += 1 }
  }

  package func end() {
    let waiters = storage.withLock { storage -> [CheckedContinuation<Void, Never>] in
      storage.running -= 1
      precondition(storage.running >= 0, "Activity.end() was called more than begin().")
      guard storage.running == 0 else { return [] }
      defer { storage.idleWaiters = [:] }
      return Array(storage.idleWaiters.values)
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// 実行中の Saga がなくなるまで待つ。
  package func waitUntilIdle() async {
    let id = storage.withLock { storage -> Int in
      defer { storage.nextWaiterID += 1 }
      return storage.nextWaiterID
    }
    // キャンセルされても待ち続けないよう、キャンセル時は待機を外して戻る。
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let isIdle = storage.withLock { storage -> Bool in
          // キャンセルの確認をロックの中で行うのは、onCancel が登録より先に走った場合に取り残されないため。
          guard storage.running > 0, !Task.isCancelled else { return true }
          storage.idleWaiters[id] = continuation
          return false
        }
        if isIdle { continuation.resume() }
      }
    } onCancel: {
      let waiter = storage.withLock { $0.idleWaiters.removeValue(forKey: id) }
      waiter?.resume()
    }
  }
}
