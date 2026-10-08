import InternalPrimitives

#if canImport(os)
  import os
#endif

/// Saga を動かすランタイム。
///
/// 1 つの状態管理（``SagaHost``）に対して 1 つ作ります。Action の配信用チャネルはこのインスタンスが所有します。
///
/// ```swift
/// let runtime = SagaRuntime(host: host)
/// runtime.run(rootSaga)
/// // Host は Action を処理した後に emit する
/// runtime.emit(action)
/// ```
///
/// Redux の Store で使う場合は、`ReduxSaga` モジュールの `SagaMiddleware` がランタイムを作って管理します。
public final class SagaRuntime<State: Sendable, Action: Sendable>: Sendable {
  let host: any SagaHost<State, Action>
  let clock: any Clock<Duration>
  let monitor: (any SagaMonitor)?
  private let onError: @Sendable (SagaError) -> Void
  package let activity = Activity()
  let multicaster: ActionMulticaster<Action>
  private let rootTasks = Locked(RootTasks())
  private let nextID = Locked(0)

  private struct RootTasks {
    var tasks: Set<SagaTask> = []
    var isStopped = false
  }

  /// ランタイムを作ります。
  ///
  /// - Parameters:
  ///   - host: Saga が Action を発行し、State を読む相手。
  ///   - clock: `delay` などが使う時計。テストでは `SagaTesting` の `TestClock` を渡します。
  ///   - monitor: Saga の起動・終了・Effect を受け取るフック。
  ///   - onError: 根（``run(_:)`` や `spawn` で起動した Saga）まで伝わった未処理のエラーを受け取る関数。
  ///     既定ではログに出力します。
  public init<Host: SagaHost>(
    host: Host,
    clock: any Clock<Duration> = ContinuousClock(),
    monitor: (any SagaMonitor)? = nil,
    onError: @escaping @Sendable (SagaError) -> Void = SagaRuntime.logError
  ) where Host.State == State, Host.Action == Action {
    self.host = host
    self.clock = clock
    self.monitor = monitor
    self.onError = onError
    self.multicaster = ActionMulticaster(activity: activity)
  }

  /// 未処理のエラーをログに出力します（`onError` の既定値）。
  ///
  /// Apple OS では `os.Logger`、それ以外では標準出力に出力します。
  @Sendable
  public static func logError(_ error: SagaError) {
    #if canImport(os)
      Logger(subsystem: "swift-redux-saga", category: "Saga")
        .error("Unhandled error in saga: \(String(describing: error), privacy: .public)")
    #else
      print("[Saga] Unhandled error in saga: \(error)")
    #endif
  }

  /// Host が処理した Action を Saga に届けます。
  ///
  /// その時点で `take` などで待っている Saga だけが受け取ります。
  public func emit(_ action: Action) {
    multicaster.emit(action)
  }

  /// Saga を起動します。
  ///
  /// 起動した Saga は、呼び出し元のタスクとは独立して動きます。``stop()`` でまとめて止められます。
  /// 未処理のエラーで終わった場合は `onError` に渡されます。
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask {
    let state = makeTaskState()
    let task = SagaTask(state: state)
    let isStopped = rootTasks.withLock { rootTasks -> Bool in
      if !rootTasks.isStopped { rootTasks.tasks.insert(task) }
      return rootTasks.isStopped
    }
    monitor?.sagaStarted(state.id, name: saga.name, parent: nil)
    guard !isStopped else {
      finish(state, .cancelled)
      return task
    }

    activity.begin()
    // ここだけ非構造化の Task を使うのは、Saga の木の根であり、親になるタスクが存在しないため。
    // 根より下（fork）はすべてタスクグループの子タスクとして動く。
    let handle = Task {
      await self.runRoot(saga, state: state)
      _ = self.rootTasks.withLock { $0.tasks.remove(task) }
    }
    state.onCancel { handle.cancel() }
    return task
  }

  /// 起動したすべての Saga をキャンセルします。以降に ``run(_:)`` した Saga はすぐにキャンセルされます。
  public func stop() {
    let tasks = rootTasks.withLock { rootTasks -> Set<SagaTask> in
      rootTasks.isStopped = true
      defer { rootTasks.tasks = [] }
      return rootTasks.tasks
    }
    for task in tasks {
      task.cancel()
    }
  }

  func makeTaskState() -> SagaTaskState {
    let id = nextID.withLock { id in
      defer { id += 1 }
      return id
    }
    return SagaTaskState(id: SagaID(rawValue: id), activity: activity)
  }

  func finish(_ state: SagaTaskState, _ result: SagaResult) {
    if state.finish(result) {
      monitor?.sagaFinished(state.id, result: result)
    }
  }

  private func runRoot(_ saga: Saga<State, Action>, state: SagaTaskState) async {
    do {
      try await runScoped(saga, state: state)
      // キャンセルを受けた Saga が CancellationError を catch して正常に終わっても、キャンセルとして扱う
      // （redux-saga と同じ）。join する側が、止めたはずの Saga を完了と誤解しないため。
      finish(state, state.isCancelRequested ? .cancelled : .completed)
    } catch {
      if error is CancellationError || state.isCancelRequested {
        finish(state, .cancelled)
      } else {
        let error = error as? SagaError ?? SagaError.propagating(error, through: saga.name)
        finish(state, .failed(error.underlying))
        onError(error)
      }
    }
  }

  /// Saga の本体を、子（fork）を持てるスコープの中で実行する。
  ///
  /// 本体と子はすべて 1 つのタスクグループの子タスクになるため、親のキャンセルは子に伝わり、
  /// 子の失敗は兄弟と本体をキャンセルして親に伝わる。本体が終わっても、子がすべて終わるまで戻らない。
  /// 呼び出し側で本体の分の `activity.begin()` 済みであること。
  ///
  /// 本体か子が失敗したら、この Saga を経路に加えた ``SagaError`` を投げる。
  func runScoped(_ saga: Saga<State, Action>, state: SagaTaskState) async throws {
    let forks = ForkQueue<ForkRequest>()
    let context = SagaContext(runtime: self, forks: forks, task: state)
    do {
      try await withThrowingDiscardingTaskGroup { group in
        group.addTask {
          defer {
            forks.close()
            state.bodyDidFinish()
          }
          try await saga.run(context)
        }
        while let request = await forks.next() {
          group.addTask { try await request.run() }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw SagaError.propagating(error, through: saga.name)
    }
  }

  /// fork された子を実行する。
  ///
  /// 子が失敗したらエラーを投げ、親のタスクグループを失敗させる（兄弟と親がキャンセルされる）。
  /// 子がキャンセルされた場合（個別のキャンセル、親からのキャンセル）はエラーを投げない。
  func runForked(
    _ saga: Saga<State, Action>, state: SagaTaskState, parent: SagaTaskState
  ) async throws {
    let signal = CancelSignal()
    state.onCancel { signal.fire() }
    do {
      try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          try await self.runScoped(saga, state: state)
          return true
        }
        group.addTask {
          await signal.wait()
          return false
        }
        // 合図（個別のキャンセル）か親のキャンセルで待機が先に終わったら、本体をキャンセルして本体の結果を待つ。
        // 本体の結果を待たずに抜けると、本体の CancellationError がタスクグループに捨てられ、完了と区別できないため。
        let bodyFinishedFirst = try await group.next() ?? true
        group.cancelAll()
        if !bodyFinishedFirst {
          _ = try await group.next()
        }
      }
      parent.childDidFinish(failed: false)
      finish(state, state.isCancelRequested || Task.isCancelled ? .cancelled : .completed)
    } catch {
      if error is CancellationError || state.isCancelRequested || Task.isCancelled {
        parent.childDidFinish(failed: false)
        finish(state, .cancelled)
      } else {
        parent.childDidFinish(failed: true)
        finish(state, .failed((error as? SagaError)?.underlying ?? error))
        throw error
      }
    }
  }

  /// スコープに子の起動を要求する。
  struct ForkRequest: Sendable {
    let run: @Sendable () async throws -> Void
  }
}
