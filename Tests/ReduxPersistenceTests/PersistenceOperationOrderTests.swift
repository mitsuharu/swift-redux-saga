import Foundation
import InternalPrimitives
import Redux
import ReduxPersistence
import SagaTesting
import Testing

/// 同期の保存 API を停止し、開始通知を非同期に受け取るためのゲート。
private final class WriteGate: Sendable {
  let started: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let condition = NSCondition()
  // NSCondition のロックを取っている間だけ読み書きする。
  private let released = Locked(false)

  init() {
    (started, continuation) = AsyncStream.makeStream()
  }

  func wait() {
    condition.lock()
    continuation.yield(())
    while !released.withLock({ $0 }) { condition.wait() }
    condition.unlock()
  }

  func open() {
    condition.lock()
    released.withLock { $0 = true }
    condition.broadcast()
    condition.unlock()
  }
}

private final class OrderedStorage: PersistenceStorage {
  let firstWrite = WriteGate()
  let failsRemoval: Bool
  private let writes = Locked(0)
  private let data = Locked<Data?>(nil)
  private let log = Locked<[String]>([])

  var operations: [String] { log.withLock { $0 } }

  init(failsRemoval: Bool = false) {
    self.failsRemoval = failsRemoval
  }

  func load(key: String) throws -> Data? { data.withLock { $0 } }

  func save(_ value: Data, key: String) throws {
    let number = writes.withLock { count in
      count += 1
      return count
    }
    if number == 1 { firstWrite.wait() }
    data.withLock { $0 = value }
    log.withLock { $0.append("save") }
  }

  func remove(key: String) throws {
    if failsRemoval { throw RemovalFailure() }
    data.withLock { $0 = nil }
    log.withLock { $0.append("clear") }
  }
}

private struct RemovalFailure: Error {}

@MainActor
@Suite(.serialized) struct PersistenceOperationOrderTests {
  @Test(arguments: [false, true])
  func aSaveScheduledDuringClearRunsAfterTheRemoval(cancelCaller: Bool) async throws {
    let storage = OrderedStorage()
    defer { storage.firstWrite.open() }
    let persistence = Persistence<Int, Int>(key: "state", storage: storage)
    let middleware = PersistenceMiddleware<Int, Int>(persistence, clock: TestClock())
    let store = Store(
      initialState: 0, reducer: Reducer<Int, Int> { $0 = $1 }, middleware: [middleware])
    store.dispatch(1)
    let firstFlush = Task { await middleware.flush() }
    var writes = storage.firstWrite.started.makeAsyncIterator()
    _ = await writes.next()

    let (started, continuation) = AsyncStream<Void>.makeStream()
    let clearing = Task { @MainActor in
      continuation.yield(())
      // この Task が clear の待機でメインアクターを手放してから、テスト側が通知を受け取る。
      try await middleware.clear()
    }
    var clearStarted = started.makeAsyncIterator()
    _ = await clearStarted.next()
    if cancelCaller { clearing.cancel() }
    store.dispatch(2)
    let secondFlush = Task { await middleware.flush() }
    storage.firstWrite.open()
    await firstFlush.value
    try await clearing.value
    await secondFlush.value

    #expect(storage.operations == ["save", "clear", "save"])
    #expect(try persistence.load() == 2)
  }

  @Test func aFailedRemovalIsReportedWithoutPreventingLaterSaves() async throws {
    let storage = OrderedStorage(failsRemoval: true)
    storage.firstWrite.open()
    let persistence = Persistence<Int, Int>(key: "state", storage: storage)
    let middleware = PersistenceMiddleware<Int, Int>(persistence, clock: TestClock())
    let store = Store(
      initialState: 0, reducer: Reducer<Int, Int> { $0 = $1 }, middleware: [middleware])
    store.dispatch(1)
    await middleware.flush()
    await #expect(throws: RemovalFailure.self) { try await middleware.clear() }
    store.dispatch(2)
    await middleware.flush()
    #expect(try persistence.load() == 2)
  }
}
