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
    var idleHandlers: [@Sendable () -> Void] = []
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

  /// 次に実行中の Saga がなくなったときに、1 回だけ呼ぶ処理を登録する。
  ///
  /// 呼び終わるまでは実行中として数える。処理の中で Saga を再開させた（`begin()` した）場合は、待っている側
  /// （``waitUntilIdle()``）は再開しない。
  package func onIdle(_ handler: @escaping @Sendable () -> Void) {
    storage.withLock { $0.idleHandlers.append(handler) }
  }

  package func end() {
    let handlers = storage.withLock { storage -> [@Sendable () -> Void] in
      storage.running -= 1
      // 数え方の不整合はテストの待ち合わせにしか影響しないため、リリースビルドではアプリを止めずに 0 に戻す。
      // デバッグビルドでは不具合として検出する。
      assert(storage.running >= 0, "Activity.end() was called more than begin().")
      storage.running = max(storage.running, 0)
      guard storage.running == 0, !storage.idleHandlers.isEmpty else { return [] }
      // 呼び終わるまで 1 つ数えておく。数えずに呼ぶと、呼び終わる前に waitUntilIdle() が戻ってしまうため。
      storage.running = 1
      defer { storage.idleHandlers = [] }
      return storage.idleHandlers
    }
    if !handlers.isEmpty {
      // ロックの外で呼ぶのは、処理の中で begin() されてもデッドロックしないため。
      for handler in handlers { handler() }
      end()
      return
    }
    let waiters = storage.withLock { storage -> [CheckedContinuation<Void, Never>] in
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
