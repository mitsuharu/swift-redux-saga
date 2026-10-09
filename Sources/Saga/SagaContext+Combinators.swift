import InternalPrimitives

extension SagaContext {
  /// すべての処理を並行に実行し、すべての結果を返します（redux-saga の `all`）。
  ///
  /// 各処理は子として fork され、それぞれの ``SagaContext`` を受け取ります。
  /// いずれかが失敗すると、残りをキャンセルしてそのエラーを投げます。処理の中で fork した子の失敗も含め、
  /// エラーは呼び出し元で catch できます。
  ///
  /// ```swift
  /// let (user, posts) = try await ctx.all(
  ///   { try await $0.call(fetchUser.execute, id) },
  ///   { try await $0.call(fetchPosts.execute, id) }
  /// )
  /// ```
  public func all<each Result: Sendable>(
    _ operations: repeat @escaping @Sendable (SagaContext) async throws -> each Result
  ) async throws -> (repeat each Result) {
    let branches = (repeat Branch(each operations))
    var tasks: [SagaTask] = []
    for branch in repeat each branches {
      tasks.append(start(branch, name: "all.branch"))
    }
    var remaining = Set(tasks.indices)
    while !remaining.isEmpty {
      let finished = try await waitForAny(of: tasks, among: remaining)
      remaining.remove(finished)
      if case .failed(let error) = outcome(of: finished, in: repeat each branches) {
        for task in tasks { task.cancel() }
        throw error
      }
    }
    return (repeat try (each branches).value())
  }

  /// 処理を並行に実行し、最初に終わった処理の結果だけを返します（redux-saga の `race`）。
  ///
  /// 戻り値は、最初に終わった処理の位置だけが値を持ち、残りは `nil` のタプルです。
  /// 負けた処理はキャンセルします。最初に終わった処理が失敗した場合は、そのエラーを投げます
  /// （処理の中で fork した子の失敗を含みます）。最初に終わった処理がキャンセルで終わった場合は
  /// `CancellationError` を投げます。
  ///
  /// ```swift
  /// let (response, timeout): (Response?, Void?) = try await ctx.race(
  ///   { try await $0.call(api.fetch) },
  ///   { try await $0.delay(.seconds(5)) }
  /// )
  /// if timeout != nil { await ctx.put(.timedOut) }
  /// ```
  public func race<each Result: Sendable>(
    _ operations: repeat @escaping @Sendable (SagaContext) async throws -> each Result
  ) async throws -> (repeat (each Result)?) {
    let branches = (repeat Branch(each operations))
    var tasks: [SagaTask] = []
    for branch in repeat each branches {
      tasks.append(start(branch, name: "race.branch"))
    }
    let winner: Int
    do {
      winner = try await waitForAny(of: tasks, among: Set(tasks.indices))
    } catch {
      for task in tasks { task.cancel() }
      throw error
    }
    for (index, task) in tasks.enumerated() where index != winner {
      task.cancel()
    }
    switch outcome(of: winner, in: repeat each branches) {
    case .completed:
      break
    case .failed(let error):
      throw error
    case .cancelled:
      // 勝者が値も失敗も残さずに終わった場合、全要素が nil のタプルを返すと
      // 正常な勝者と区別できないため、キャンセルとして投げる。
      throw CancellationError()
    }
    var index = 0
    func pick<R>(_ branch: Branch<R>) -> R? {
      defer { index += 1 }
      return index == winner ? try? branch.value() : nil
    }
    return (repeat pick(each branches))
  }

  private func start<R>(_ branch: Branch<R>, name: String) -> SagaTask {
    // 失敗を fork の仕組みで親に伝えると、呼び出し元で catch できないため、結果として持ち帰る。
    // 処理の本体だけを do / catch で囲まないのは、処理の中で fork した子の失敗が本体を通らずに伝わるため。
    fork(
      Saga(name) { ctx in branch.finish(.success(try await branch.operation(ctx))) },
      waitsForFirstEffect: true,
      onFailure: { branch.finish(.failure($0)) })
  }

  /// 位置 `index` の処理の終わり方を返す。値も失敗も残していなければキャンセルとみなす。
  private func outcome<each R>(of index: Int, in branches: repeat Branch<each R>) -> SagaResult {
    var current = 0
    var found = SagaResult.cancelled
    for branch in repeat each branches {
      if current == index {
        switch branch.result {
        case .success?: found = .completed
        case .failure(let error)?: found = .failed(error)
        case nil: break
        }
      }
      current += 1
    }
    return found
  }

  /// `candidates` の位置の SagaTask のうち、最初に終わったものの位置を返す。
  private func waitForAny(of tasks: [SagaTask], among candidates: Set<Int>) async throws -> Int {
    if let finished = candidates.sorted().first(where: { !tasks[$0].isRunning }) {
      return finished
    }
    let activity = runtime.activity
    let gate = Locked<CheckedContinuation<Int, any Error>?>(nil)
    // 待機を 1 回だけ取り出す。最初に終わった子とキャンセルのうち、先に来た方だけが再開する。
    let takeGate: @Sendable () -> CheckedContinuation<Int, any Error>? = {
      gate.withLock { gate in
        defer { gate = nil }
        return gate
      }
    }
    let fire: @Sendable (Int) -> Void = { index in
      guard let continuation = takeGate() else { return }
      activity.begin()
      continuation.resume(returning: index)
    }
    var observers: [(SagaTask, Int)] = []
    defer {
      for (task, id) in observers { task.state.removeObserver(id) }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let waiting = gate.withLock { gate -> Bool in
          guard !Task.isCancelled else { return false }
          gate = continuation
          return true
        }
        guard waiting else {
          continuation.resume(throwing: CancellationError())
          return
        }
        // fire が数えてから resume するので、ここで先に減らしても負にならない。
        activity.end()
        for index in candidates.sorted() {
          let task = tasks[index]
          if let id = task.state.addObserver({ fire(index) }) {
            observers.append((task, id))
          } else {
            fire(index)
          }
        }
      }
    } onCancel: {
      guard let continuation = takeGate() else { return }
      activity.begin()
      continuation.resume(throwing: CancellationError())
    }
  }

  /// all / race の 1 つの処理と、その結果。
  fileprivate final class Branch<R: Sendable>: Sendable {
    let operation: @Sendable (SagaContext) async throws -> R
    private let storage = Locked<Swift.Result<R, any Error>?>(nil)

    init(_ operation: @escaping @Sendable (SagaContext) async throws -> R) {
      self.operation = operation
    }

    var result: Swift.Result<R, any Error>? {
      storage.withLock { $0 }
    }

    func finish(_ result: Swift.Result<R, any Error>) {
      storage.withLock { $0 = result }
    }

    /// 結果の値を返す。失敗していればエラーを投げる。終わっていなければキャンセルとして扱う。
    func value() throws -> R {
      guard let result else { throw CancellationError() }
      return try result.get()
    }
  }
}
