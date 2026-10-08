import InternalPrimitives
import Redux
import ReduxSaga
import Saga
import SagaTesting

/// 本物の `Store` とミドルウェア（Saga を含む）を動かし、Action と State の変化を 1 つずつ検証するテスト支援。
///
/// ```swift
/// @Test func increment() async throws {
///   let store = TestStore(initialState: AppState(), reducer: appReducer, saga: appSagas.root)
///   try await store.send(.counter(.fetch)) {
///     $0.counter.isLoading = true
///   }
///   try store.receive(.counter(.loaded(10))) {
///     $0.counter.isLoading = false
///     $0.counter.count = 10
///   }
///   try await store.finish()
/// }
/// ```
///
/// - `send` の `assert` には、送った Action を reducer に適用した直後の State を書きます（Saga が動く前）。
/// - Saga やミドルウェアが dispatch した Action は `receive(_:assert:)` で順に確かめます。
/// - 待ち合わせは実時間ではなく「すべての Saga が Effect で止まったか」で行います。
@MainActor
public final class TestStore<State: Sendable & Equatable, Action: Sendable> {
  /// テストしている Store。
  public let store: Store<State, Action>
  /// Saga の `delay` などが使う時計。
  public let clock: TestClock
  private let recorder: Recorder
  private let sagaMiddleware: SagaMiddleware<State, Action>?
  private let errorStorage = Locked<[SagaError]>([])
  private let sagaTask: SagaTask?
  private var checkedState: State

  /// テスト用の Store を作ります。
  ///
  /// - Parameters:
  ///   - initialState: State の初期値。
  ///   - reducer: reducer。
  ///   - middleware: Saga 以外のミドルウェア。
  ///   - saga: 起動する Saga。省略すると Saga を使いません。
  ///   - clock: Saga の `delay` などが使う時計。
  public init(
    initialState: State,
    reducer: Reducer<State, Action>,
    middleware: [any Middleware<State, Action>] = [],
    saga: Saga<State, Action>? = nil,
    clock: TestClock = TestClock()
  ) {
    let recorder = Recorder()
    let errors = errorStorage
    let sagaMiddleware =
      saga == nil
      ? nil
      : SagaMiddleware<State, Action>(clock: clock) { error in
        errors.withLock { $0.append(error) }
      }
    // 記録用のミドルウェアを先頭に置き、Saga やほかのミドルウェアが dispatch した Action もすべて記録する。
    var allMiddleware: [any Middleware<State, Action>] = [recorder]
    allMiddleware += middleware
    if let sagaMiddleware { allMiddleware.append(sagaMiddleware) }

    self.store = Store(initialState: initialState, reducer: reducer, middleware: allMiddleware)
    self.clock = clock
    self.recorder = recorder
    self.sagaMiddleware = sagaMiddleware
    self.checkedState = initialState
    if let saga, let sagaMiddleware {
      sagaTask = sagaMiddleware.run(saga)
    } else {
      sagaTask = nil
    }
  }

  /// 現在の State。
  public var state: State {
    store.state
  }

  /// Saga やミドルウェアが dispatch し、まだ `receive(_:assert:)` で確かめていない Action。
  public var unreceivedActions: [Action] {
    recorder.records.map(\.action)
  }

  /// Saga の根まで伝わった未処理のエラー。
  public var sagaErrors: [SagaError] {
    errorStorage.withLock { $0 }
  }

  /// すべての Saga が Effect で止まるまで待ちます。
  public func settle() async {
    await sagaMiddleware?.waitUntilIdle()
  }

  /// Action を dispatch し、State の変化を確かめてから、Saga が止まるまで待ちます。
  ///
  /// - Parameters:
  ///   - action: 送る Action。
  ///   - assert: 期待する State の変化。直前に確かめた State を書き換えて、Action を適用した直後の State にしてください。
  ///     省略すると State を確かめません。
  ///   - fileID: 失敗の報告に使うファイル。
  ///   - line: 失敗の報告に使う行。
  /// - Throws: State が期待と異なる場合は ``TestStoreFailure``。
  public func send(
    _ action: Action,
    assert: ((inout State) -> Void)? = nil,
    fileID: String = #fileID,
    line: Int = #line
  ) async throws {
    await settle()
    let unreceived = recorder.records.count
    store.dispatch(action)
    // 送った Action 自身の記録は、receive の対象にしない。
    let own = recorder.removeRecord(at: unreceived)
    try check(own?.state ?? store.state, assert, after: "\(action)", fileID: fileID, line: line)
    await settle()
  }

  /// Saga やミドルウェアが次に dispatch した Action が、期待した Action と等しいかを確かめます。
  ///
  /// - Parameters:
  ///   - expected: 期待する Action。
  ///   - assert: 期待する State の変化。省略すると State を確かめません。
  ///   - fileID: 失敗の報告に使うファイル。
  ///   - line: 失敗の報告に使う行。
  /// - Throws: Action がない、等しくない、または State が期待と異なる場合は ``TestStoreFailure``。
  public func receive(
    _ expected: Action,
    assert: ((inout State) -> Void)? = nil,
    fileID: String = #fileID,
    line: Int = #line
  ) throws where Action: Equatable {
    let record = try nextRecord(fileID: fileID, line: line)
    guard record.action == expected else {
      throw TestStoreFailure(
        "Received \(record.action), but expected \(expected).", fileID: fileID, line: line)
    }
    try check(record.state, assert, after: "\(record.action)", fileID: fileID, line: line)
  }

  /// Saga やミドルウェアが次に dispatch した Action がパターンに一致するかを確かめ、取り出した値を返します。
  @discardableResult
  public func receive<Value>(
    _ pattern: ActionPattern<Action, Value>,
    assert: ((inout State) -> Void)? = nil,
    fileID: String = #fileID,
    line: Int = #line
  ) throws -> Value {
    let record = try nextRecord(fileID: fileID, line: line)
    guard let value = pattern.match(record.action) else {
      throw TestStoreFailure(
        "Received \(record.action), which does not match the pattern.", fileID: fileID, line: line)
    }
    try check(record.state, assert, after: "\(record.action)", fileID: fileID, line: line)
    return value
  }

  /// まだ確かめていない Action を捨てます。確かめた State は現在の State に進めます。
  public func skipReceivedActions() {
    _ = recorder.removeAll()
    checkedState = store.state
  }

  /// 時計を進めます。進めた範囲で起きる Saga を順に起こし、そのたびに Saga が止まるまで待ちます。
  public func advance(by duration: Duration) async {
    await settle()
    let target = clock.now.advanced(by: duration)
    while let next = clock.nextDeadline, next <= target {
      clock.advance(to: next)
      await settle()
    }
    clock.advance(to: target)
    await settle()
  }

  /// テストを終えます。Saga を止め、確かめていない Action や未処理のエラーがないことを確かめます。
  public func finish(fileID: String = #fileID, line: Int = #line) async throws {
    await settle()
    sagaMiddleware?.stop()
    if let sagaTask { _ = try? await sagaTask.join() }
    await settle()
    let remaining = recorder.removeAll().map(\.action)
    if !remaining.isEmpty {
      throw TestStoreFailure(
        "There are actions that were not received: \(remaining)", fileID: fileID, line: line)
    }
    let errors = sagaErrors
    if !errors.isEmpty {
      throw TestStoreFailure(
        "There are unhandled saga errors: \(errors)", fileID: fileID, line: line)
    }
  }

  private func nextRecord(fileID: String, line: Int) throws -> Recorder.Record {
    guard let record = recorder.removeRecord(at: 0) else {
      throw TestStoreFailure("No action was dispatched.", fileID: fileID, line: line)
    }
    return record
  }

  private func check(
    _ actual: State, _ assert: ((inout State) -> Void)?, after action: String,
    fileID: String, line: Int
  ) throws {
    defer { checkedState = actual }
    guard let assert else { return }
    var expected = checkedState
    assert(&expected)
    guard expected == actual else {
      throw TestStoreFailure(
        "State after \(action) does not match.\n  expected: \(expected)\n  actual:   \(actual)",
        fileID: fileID, line: line)
    }
  }

  /// dispatch された Action と、reducer を適用した後の State を記録するミドルウェア。
  private final class Recorder: Middleware {
    struct Record {
      let action: Action
      let state: State
    }

    private(set) var records: [Record] = []

    func handle(_ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void) {
      next(action)
      records.append(Record(action: action, state: store.state))
    }

    func removeRecord(at index: Int) -> Record? {
      guard records.indices.contains(index) else { return nil }
      return records.remove(at: index)
    }

    func removeAll() -> [Record] {
      defer { records = [] }
      return records
    }
  }
}

/// ``TestStore`` の検証が失敗したことを表すエラー。
public struct TestStoreFailure: Error, CustomStringConvertible {
  /// 失敗の内容。
  public let message: String
  /// 検証を呼び出したファイル。
  public let fileID: String
  /// 検証を呼び出した行。
  public let line: Int

  init(_ message: String, fileID: String, line: Int) {
    self.message = message
    self.fileID = fileID
    self.line = line
  }

  public var description: String {
    "\(fileID):\(line): \(message)"
  }
}
