import InternalPrimitives
import Saga

/// Saga を状態管理なしで動かし、結果（発行された Action と State）を検証するためのテスト支援。
///
/// redux-saga のように Effect を 1 ステップずつ取り出して検証するテストは、Swift にジェネレーターがないため
/// 再現しません。代わりに Saga を実際に動かし、外から Action を送り、Saga が発行した Action と State を確かめます。
///
/// ```swift
/// @Test func fetchUser() async throws {
///   let tester = SagaTester(
///     initialState: AppState(),
///     reduce: appReducer.reduce,
///     saga: UserSagas(fetchUser: .stub(User(id: 1))).root
///   )
///   await tester.send(.user(.fetch(1)))
///   try tester.receive(.user(.fetched(User(id: 1))))
///   #expect(tester.state.user == User(id: 1))
///   try await tester.finish()
/// }
/// ```
///
/// 待ち合わせは実時間ではなく「すべての Saga が Effect（`take` / `delay` / `join` など）で止まったか」で行うため、
/// テストが実行環境の速さに左右されません。`call` で呼んだ関数が終わらない場合（実際の通信など）は待ち続けるので、
/// テストではすぐ終わる差し替え（スタブ）を渡してください。
public final class SagaTester<State: Sendable, Action: Sendable>: Sendable {
  private let host: Host
  let runtime: SagaRuntime<State, Action>
  private let task: SagaTask
  /// テストで使う時計。
  public let clock: TestClock

  /// Saga を起動します。
  ///
  /// - Parameters:
  ///   - initialState: State の初期値。
  ///   - reduce: Action を State に適用する関数。Redux の場合は `reducer.reduce` を渡します。
  ///   - saga: テストする Saga。
  ///   - clock: `delay` などが使う時計。
  ///   - monitor: Saga の起動・終了・Effect を受け取るフック。
  public init(
    initialState: State,
    reduce: @escaping @Sendable (inout State, Action) -> Void,
    saga: Saga<State, Action>,
    clock: TestClock = TestClock(),
    monitor: (any SagaMonitor)? = nil
  ) {
    let host = Host(state: initialState, reduce: reduce)
    let runtime = SagaRuntime(host: host, clock: clock, monitor: monitor) { error in
      host.record(error)
    }
    host.attach(runtime)
    self.host = host
    self.runtime = runtime
    self.clock = clock
    self.task = runtime.run(saga)
  }

  /// 現在の State。
  public var state: State {
    host.state
  }

  /// Saga が発行し、まだ `receive(_:)` で確かめていない Action。
  public var unreceivedActions: [Action] {
    host.received
  }

  /// 根まで伝わった未処理のエラー。
  public var errors: [SagaError] {
    host.errors
  }

  /// テストする Saga がまだ動いているかどうか。
  public var isRunning: Bool {
    task.isRunning
  }

  /// すべての Saga が Effect で止まるまで待ちます。
  public func settle() async {
    await runtime.activity.waitUntilIdle()
  }

  /// 外（UI など）から Action を送ります。State に適用し、Saga に届け、Saga が止まるまで待ちます。
  public func send(_ action: Action) async {
    await settle()
    host.apply(action)
    runtime.emit(action)
    await settle()
  }

  /// 時計を進めます。進めた範囲で起きる Saga を順に起こし、そのたびに Saga が止まるまで待ちます。
  ///
  /// 起きた Saga がさらに `delay` し、その起床時刻が進めた範囲に入っている場合も起こします。
  public func advance(by duration: Duration) async {
    await clock.advance(by: duration) { await settle() }
  }

  /// Saga が次に発行した Action を取り出し、期待した Action と等しいかを確かめます。
  ///
  /// - Throws: Action がない、または等しくない場合は ``SagaTesterFailure``。
  public func receive(
    _ expected: Action, fileID: String = #fileID, line: Int = #line
  ) throws where Action: Equatable {
    let actual = try receiveNext(fileID: fileID, line: line)
    guard actual == expected else {
      throw SagaTesterFailure(
        "Received \(actual), but expected \(expected).", fileID: fileID, line: line)
    }
  }

  /// Saga が次に発行した Action を取り出し、パターンに一致すれば取り出した値を返します。
  ///
  /// - Throws: Action がない、または一致しない場合は ``SagaTesterFailure``。
  @discardableResult
  public func receive<Value>(
    _ pattern: ActionPattern<Action, Value>, fileID: String = #fileID, line: Int = #line
  ) throws -> Value {
    let actual = try receiveNext(fileID: fileID, line: line)
    guard let value = pattern.match(actual) else {
      throw SagaTesterFailure(
        "Received \(actual), which does not match the pattern.", fileID: fileID, line: line)
    }
    return value
  }

  /// まだ確かめていない Action を捨てます。
  public func skipReceivedActions() {
    _ = host.takeAllReceived()
  }

  /// テストを終えます。Saga をすべてキャンセルし、確かめていない Action や未処理のエラーがないことを確かめます。
  ///
  /// - Throws: 確かめていない Action か未処理のエラーがある場合は ``SagaTesterFailure``。
  public func finish(fileID: String = #fileID, line: Int = #line) async throws {
    await settle()
    runtime.stop()
    _ = try? await task.join()
    await settle()
    let remaining = host.takeAllReceived()
    if !remaining.isEmpty {
      throw SagaTesterFailure(
        "There are actions that were not received: \(remaining)", fileID: fileID, line: line)
    }
    let errors = host.errors
    if !errors.isEmpty {
      throw SagaTesterFailure(
        "There are unhandled errors: \(errors)", fileID: fileID, line: line)
    }
  }

  private func receiveNext(fileID: String, line: Int) throws -> Action {
    guard let action = host.popReceived() else {
      throw SagaTesterFailure("No action was put by the saga.", fileID: fileID, line: line)
    }
    return action
  }

  /// テスト用の Host。State を reduce で更新し、Saga が発行した Action を記録する。
  private final class Host: SagaHost {
    private struct Storage {
      var state: State
      var received: [Action] = []
      var errors: [SagaError] = []
      var runtime: SagaRuntime<State, Action>?
    }

    private let storage: Locked<Storage>
    private let reduce: @Sendable (inout State, Action) -> Void

    init(state: State, reduce: @escaping @Sendable (inout State, Action) -> Void) {
      storage = Locked(Storage(state: state))
      self.reduce = reduce
    }

    func attach(_ runtime: SagaRuntime<State, Action>) {
      storage.withLock { $0.runtime = runtime }
    }

    var state: State { storage.withLock { $0.state } }
    var received: [Action] { storage.withLock { $0.received } }
    var errors: [SagaError] { storage.withLock { $0.errors } }

    func record(_ error: SagaError) {
      storage.withLock { $0.errors.append(error) }
    }

    func apply(_ action: Action) {
      storage.withLock { [reduce] in reduce(&$0.state, action) }
    }

    func popReceived() -> Action? {
      storage.withLock { $0.received.isEmpty ? nil : $0.received.removeFirst() }
    }

    func takeAllReceived() -> [Action] {
      storage.withLock { storage in
        defer { storage.received = [] }
        return storage.received
      }
    }

    func dispatch(_ action: Action) async {
      let runtime = storage.withLock { [reduce] storage in
        reduce(&storage.state, action)
        storage.received.append(action)
        return storage.runtime
      }
      runtime?.emit(action)
    }

    func state() async -> State {
      state
    }
  }
}

/// ``SagaTester`` の検証が失敗したことを表すエラー。
public struct SagaTesterFailure: Error, CustomStringConvertible {
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
