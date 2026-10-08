import InternalPrimitives

/// 起動した Saga を表すハンドル。
///
/// ``cancel()`` で止め、``join()`` で終わるのを待てます。
public struct SagaTask: Sendable, Hashable {
  let state: SagaTaskState

  init(state: SagaTaskState) {
    self.state = state
  }

  /// Saga の識別子。``SagaMonitor`` に渡される識別子と同じです。
  public var id: SagaID {
    state.id
  }

  /// Saga がまだ動いているかどうか。
  public var isRunning: Bool {
    state.status == nil
  }

  /// Saga がキャンセルで終わったかどうか。
  public var isCancelled: Bool {
    if case .cancelled = state.status { true } else { false }
  }

  /// Saga をキャンセルします。終わっている場合は何もしません。
  ///
  /// fork した Saga をキャンセルしても、親にはエラーが伝播しません。
  public func cancel() {
    state.cancel()
  }

  /// Saga が終わるまで待ちます。
  ///
  /// Saga の外（アプリやテスト）から待つためのメソッドです。Saga の中では ``SagaContext/join(_:)`` を使ってください。
  ///
  /// - Throws: Saga が失敗した場合はそのエラー、キャンセルされた場合は `CancellationError`。
  ///   待っている側がキャンセルされた場合も `CancellationError` を投げます（待たれている Saga は止まりません）。
  public func join() async throws {
    try await state.join(fromSaga: false)
  }

  public static func == (lhs: SagaTask, rhs: SagaTask) -> Bool {
    lhs.state === rhs.state
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(state))
  }
}

/// ``SagaTask`` の中身。状態の遷移とキャンセルの要求、join の待ち合わせを管理する。
final class SagaTaskState: Sendable {
  private struct Storage {
    var status: SagaResult?
    var cancelRequested = false
    var cancelHandler: (@Sendable () -> Void)?
    var nextJoinerID = 0
    var joiners: [Int: Joiner] = [:]
  }

  private struct Joiner {
    let continuation: CheckedContinuation<Void, any Error>
    /// Saga の中から待っているか。Saga なら再開時に Activity を数える。
    let fromSaga: Bool
  }

  let id: SagaID
  private let storage = Locked(Storage())
  private let activity: Activity

  init(id: SagaID, activity: Activity) {
    self.id = id
    self.activity = activity
  }

  var status: SagaResult? {
    storage.withLock { $0.status }
  }

  var isCancelRequested: Bool {
    storage.withLock { $0.cancelRequested }
  }

  /// キャンセルを要求されたときの処理を登録する。すでに要求されていれば、その場で呼ぶ。
  func onCancel(_ handler: @escaping @Sendable () -> Void) {
    let requested = storage.withLock { storage -> Bool in
      if storage.cancelRequested { return true }
      storage.cancelHandler = handler
      return false
    }
    if requested { handler() }
  }

  func cancel() {
    let handler = storage.withLock { storage -> (@Sendable () -> Void)? in
      guard storage.status == nil, !storage.cancelRequested else { return nil }
      storage.cancelRequested = true
      defer { storage.cancelHandler = nil }
      return storage.cancelHandler
    }
    handler?()
  }

  /// 終わり方を確定し、join で待っている側を再開する。2 回目以降は無視して `false` を返す。
  @discardableResult
  func finish(_ status: SagaResult) -> Bool {
    let joiners = storage.withLock { storage -> [Joiner]? in
      guard storage.status == nil else { return nil }
      storage.status = status
      storage.cancelHandler = nil
      defer { storage.joiners = [:] }
      return Array(storage.joiners.values)
    }
    guard let joiners else { return false }
    for joiner in joiners {
      if joiner.fromSaga { activity.begin() }
      Self.resume(joiner.continuation, with: status)
    }
    return true
  }

  func join(fromSaga: Bool) async throws {
    let id = storage.withLock { storage -> Int in
      defer { storage.nextJoinerID += 1 }
      return storage.nextJoinerID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let finished = storage.withLock { storage -> Result<SagaResult?, CancellationError> in
          if let status = storage.status { return .success(status) }
          guard !Task.isCancelled else { return .failure(CancellationError()) }
          storage.joiners[id] = Joiner(continuation: continuation, fromSaga: fromSaga)
          return .success(nil)
        }
        switch finished {
        case .success(let status?):
          Self.resume(continuation, with: status)
        case .success(nil):
          if fromSaga { activity.end() }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      guard let joiner = storage.withLock({ $0.joiners.removeValue(forKey: id) }) else { return }
      if joiner.fromSaga { activity.begin() }
      joiner.continuation.resume(throwing: CancellationError())
    }
  }

  private static func resume(
    _ continuation: CheckedContinuation<Void, any Error>, with status: SagaResult
  ) {
    switch status {
    case .completed: continuation.resume()
    case .failed(let error): continuation.resume(throwing: error)
    case .cancelled: continuation.resume(throwing: CancellationError())
    }
  }
}
