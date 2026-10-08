import InternalPrimitives

extension SagaContext {
  /// すべての処理を並行に実行し、すべての結果を返します（redux-saga の `all`）。
  ///
  /// 各処理は子として fork され、それぞれの ``SagaContext`` を受け取ります。
  /// いずれかが失敗すると、残りをキャンセルしてそのエラーを投げます。エラーは呼び出し元で catch できます。
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
      if let error = failure(of: finished, in: repeat each branches) {
        for task in tasks { task.cancel() }
        throw error
      }
    }
    return (repeat try (each branches).value())
  }

  /// 処理を並行に実行し、最初に終わった処理の結果だけを返します（redux-saga の `race`）。
  ///
  /// 戻り値は、最初に終わった処理の位置だけが値を持ち、残りは `nil` のタプルです。
  /// 負けた処理はキャンセルします。最初に終わった処理が失敗した場合は、そのエラーを投げます。
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
    if let error = failure(of: winner, in: repeat each branches) {
      throw error
    }
    var index = 0
    func pick<R>(_ branch: Branch<R>) -> R? {
      defer { index += 1 }
      return index == winner ? try? branch.value() : nil
    }
    return (repeat pick(each branches))
  }

  private func start<R>(_ branch: Branch<R>, name: String) -> SagaTask {
    fork(name) { ctx in
      do {
        branch.finish(.success(try await branch.operation(ctx)))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // 失敗を fork の仕組みで親に伝えると、呼び出し元で catch できないため、結果として持ち帰る。
        branch.finish(.failure(error))
      }
    }
  }

  /// 位置 `index` の処理が失敗していれば、そのエラーを返す。
  private func failure<each R>(of index: Int, in branches: repeat Branch<each R>) -> (any Error)? {
    var current = 0
    var found: (any Error)?
    for branch in repeat each branches {
      if current == index, case .failure(let error)? = branch.result { found = error }
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
    let fire: @Sendable (Int) -> Void = { index in
      guard
        let continuation = gate.withLock({ gate in
          defer { gate = nil }
          return gate
        })
      else {
        return
      }
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
      guard
        let continuation = gate.withLock({ gate in
          defer { gate = nil }
          return gate
        })
      else {
        return
      }
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
