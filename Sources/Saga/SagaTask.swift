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
    var observers: [Int: @Sendable () -> Void] = [:]
    // 以下は Activity の数え方のための状態（Activity.swift を参照）。
    var liveChildren = 0
    var isBodyDone = false
    var holdsUnit = false
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
    let (handler, acquired) = storage.withLock {
      storage -> ((@Sendable () -> Void)?, Bool) in
      guard storage.status == nil, !storage.cancelRequested else { return (nil, false) }
      storage.cancelRequested = true
      defer { storage.cancelHandler = nil }
      return (storage.cancelHandler, Self.acquireUnit(&storage))
    }
    // キャンセルが Effect の待機を外すまでの間も実行中として数える（終わるまで手放さない）。
    if acquired { activity.begin() }
    handler?()
  }

  // MARK: - Activity の数え方
  //
  // Saga の本体が実行中のあいだは 1 つ数える。Effect で止まっている間は数えない（Effect の側で増減する）。
  // 本体が終わってから finish するまでの「後始末」も 1 つ数える。後始末の単位（unit）は次のどれかで取得し、
  // finish で手放す。
  // - 本体が終わった時点で子がいなければ、本体の分をそのまま後始末の分にする。
  // - 本体が終わって子を待っている間は数えない。最後の子が終わるときに、子が親の分を取得する。
  // - 子が失敗したとき、子が親の分を取得する（親が兄弟と本体をキャンセルし終えるまで数えるため）。
  // - キャンセルを要求されたとき。
  // いずれも、取得する側は自分の分を手放す前に取得する（数が一時的に 0 になって settle が早く返らないため）。

  private static func acquireUnit(_ storage: inout Storage) -> Bool {
    guard !storage.holdsUnit, storage.status == nil else { return false }
    storage.holdsUnit = true
    return true
  }

  /// 後始末の分を取得する。すでに持っていれば何もしない。
  func acquireUnit() {
    if storage.withLock({ Self.acquireUnit(&$0) }) {
      activity.begin()
    }
  }

  /// 本体が終わったときに呼ぶ。本体の分を後始末の分にするか、手放す。
  func bodyDidFinish() {
    let release = storage.withLock { storage -> Bool in
      storage.isBodyDone = true
      if storage.liveChildren == 0, !storage.holdsUnit {
        storage.holdsUnit = true
        return false
      }
      return true
    }
    if release { activity.end() }
  }

  /// 子を fork したときに呼ぶ。
  func childDidStart() {
    storage.withLock { $0.liveChildren += 1 }
  }

  /// 子が終わったときに、子が自分の分を手放す前に呼ぶ。
  func childDidFinish(failed: Bool) {
    let needsUnit = storage.withLock { storage -> Bool in
      storage.liveChildren -= 1
      return failed || (storage.liveChildren == 0 && storage.isBodyDone)
    }
    if needsUnit { acquireUnit() }
  }

  /// 終わったときに呼ぶ処理を登録し、登録の ID を返す。すでに終わっていれば登録せずに `nil` を返す。
  func addObserver(_ observer: @escaping @Sendable () -> Void) -> Int? {
    storage.withLock { storage -> Int? in
      guard storage.status == nil else { return nil }
      defer { storage.nextJoinerID += 1 }
      storage.observers[storage.nextJoinerID] = observer
      return storage.nextJoinerID
    }
  }

  func removeObserver(_ id: Int) {
    _ = storage.withLock { $0.observers.removeValue(forKey: id) }
  }

  /// 終わり方を確定し、join で待っている側を再開する。2 回目以降は無視して `false` を返す。
  ///
  /// `didFinish` は、終わり方を確定した直後、待っている側を再開する前に呼ぶ（モニタへの通知用）。
  @discardableResult
  func finish(_ status: SagaResult, didFinish: () -> Void = {}) -> Bool {
    let waiting = storage.withLock { storage -> ([Joiner], [@Sendable () -> Void])? in
      guard storage.status == nil else { return nil }
      storage.status = status
      storage.cancelHandler = nil
      defer {
        storage.joiners = [:]
        storage.observers = [:]
      }
      return (Array(storage.joiners.values), Array(storage.observers.values))
    }
    guard let (joiners, observers) = waiting else { return false }
    didFinish()
    for joiner in joiners {
      if joiner.fromSaga { activity.begin() }
      Self.resume(joiner.continuation, with: status)
    }
    for observer in observers {
      observer()
    }
    // join している側を数えてから手放す。
    let holdsUnit = storage.withLock { storage in
      defer { storage.holdsUnit = false }
      return storage.holdsUnit
    }
    if holdsUnit { activity.end() }
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
