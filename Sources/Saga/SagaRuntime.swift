import InternalPrimitives

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
  package let activity = Activity()
  let multicaster: ActionMulticaster<Action>
  private let rootTasks = Locked(RootTasks())

  private struct RootTasks {
    var tasks: Set<SagaTask> = []
    var isStopped = false
  }

  /// ランタイムを作ります。
  ///
  /// - Parameters:
  ///   - host: Saga が Action を発行し、State を読む相手。
  ///   - clock: `delay` などが使う時計。テストでは `SagaTesting` の `TestClock` を渡します。
  public init<Host: SagaHost>(
    host: Host,
    clock: any Clock<Duration> = ContinuousClock()
  ) where Host.State == State, Host.Action == Action {
    self.host = host
    self.clock = clock
    self.multicaster = ActionMulticaster(activity: activity)
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
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask {
    let state = SagaTaskState(activity: activity)
    let task = SagaTask(state: state)
    let isStopped = rootTasks.withLock { rootTasks -> Bool in
      if !rootTasks.isStopped { rootTasks.tasks.insert(task) }
      return rootTasks.isStopped
    }
    guard !isStopped else {
      state.finish(.cancelled)
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

  private func runRoot(_ saga: Saga<State, Action>, state: SagaTaskState) async {
    do {
      try await runScoped(saga)
      // キャンセルを受けた Saga が CancellationError を catch して正常に終わっても、キャンセルとして扱う
      // （redux-saga と同じ）。join する側が、止めたはずの Saga を完了と誤解しないため。
      state.finish(state.isCancelRequested ? .cancelled : .completed)
    } catch {
      if error is CancellationError || state.isCancelRequested {
        state.finish(.cancelled)
      } else {
        state.finish(.failed(error))
      }
    }
  }

  /// Saga の本体を、子（fork）を持てるスコープの中で実行する。
  ///
  /// 本体と子はすべて 1 つのタスクグループの子タスクになるため、親のキャンセルは子に伝わり、
  /// 子の失敗は兄弟と本体をキャンセルして親に伝わる。本体が終わっても、子がすべて終わるまで戻らない。
  /// 呼び出し側で `activity.begin()` 済みであること（本体の終了時に `end()` する）。
  func runScoped(_ saga: Saga<State, Action>) async throws {
    let forks = ForkQueue<ForkRequest>()
    let context = SagaContext(runtime: self, forks: forks)
    try await withThrowingDiscardingTaskGroup { group in
      group.addTask {
        defer {
          forks.close()
          self.activity.end()
        }
        try await saga.run(context)
      }
      while let request = await forks.next() {
        group.addTask { try await request.run() }
      }
    }
  }

  /// スコープに子の起動を要求する。
  struct ForkRequest: Sendable {
    let run: @Sendable () async throws -> Void
  }
}
