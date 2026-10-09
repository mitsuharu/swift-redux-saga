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
  let onError: @Sendable (SagaError) -> Void
  package let activity: Activity
  let multicaster: ActionMulticaster<Action>
  private let rootTasks = Locked(RootTasks())
  private let nextID: Locked<Int>
  private let nextScopeID = Locked(0)
  /// 接続した子のランタイム（``run(_:state:action:embed:)``）。キーは接続ごとの番号。
  let scopes = Locked<[Int: ScopedRuntime]>([:])

  /// 接続した子のランタイムに、Action を届けたり止めたりする関数。
  struct ScopedRuntime: Sendable {
    let emit: @Sendable (Action) -> Void
    let stop: @Sendable () -> Void
  }

  private let startup = Locked(Startup())

  private struct RootTasks {
    var tasks: Set<SagaTask> = []
    var isStopped = false
  }

  /// 起動中（最初の ``run(_:)`` から、その間に起動した Saga がすべて最初の Effect に達するまで）の状態。
  private struct Startup {
    var hasStarted = false
    var isBuffering = false
    /// 起動中に emit された Action。
    var actions: [Action] = []
    /// 起動中に起動し、まだ最初の Effect に達していない Saga。
    var pending: Set<SagaID> = []
    /// 溜めた Action を届けている途中か（届けるのは 1 か所ずつにして、順序を保つ）。
    var isDelivering = false
  }

  /// ランタイムを作ります。
  ///
  /// - Parameters:
  ///   - host: Saga が Action を発行し、State を読む相手。
  ///   - clock: `delay` などが使う時計。テストでは `SagaTesting` の `TestClock` を渡します。
  ///   - monitor: Saga の起動・終了・Effect を受け取るフック。
  ///   - onError: 根（``run(_:)`` や `spawn` で起動した Saga）まで伝わった未処理のエラーを受け取る関数。
  ///     既定ではログに出力します。
  public convenience init<Host: SagaHost>(
    host: Host,
    clock: any Clock<Duration> = ContinuousClock(),
    monitor: (any SagaMonitor)? = nil,
    onError: @escaping @Sendable (SagaError) -> Void = SagaRuntime.logError
  ) where Host.State == State, Host.Action == Action {
    self.init(
      host: host, clock: clock, monitor: monitor, onError: onError,
      activity: Activity(), nextID: Locked(0))
  }

  /// 親のランタイムと Activity と ID の連番を共有して作る（子のランタイム用）。
  ///
  /// Activity を共有するのは、親の ``waitUntilIdle()`` やテストの `settle()` が子の Saga も待つため。
  /// ID の連番を共有するのは、モニタで親子の Saga の ID が重ならないため。
  init(
    host: any SagaHost<State, Action>,
    clock: any Clock<Duration>,
    monitor: (any SagaMonitor)?,
    onError: @escaping @Sendable (SagaError) -> Void,
    activity: Activity,
    nextID: Locked<Int>
  ) {
    self.host = host
    self.clock = clock
    self.monitor = monitor
    self.onError = onError
    self.activity = activity
    self.nextID = nextID
    self.multicaster = ActionMulticaster(activity: activity)
    // ランタイムは Activity を所有しているため、弱参照にして循環させない。
    activity.onIdle { [weak self] in self?.deliverStartupActions() }
  }

  /// 未処理のエラーをログに出力します（`onError` の既定値）。
  ///
  /// Apple OS では `os.Logger` に出力します。エラーの内容は個人情報を含み得るため `.private`
  /// （Xcode から実行しているときのコンソールには表示され、端末のログでは伏せられる）、
  /// Saga の経路は `.public` で出力します。それ以外の OS では標準出力に出力します。
  @Sendable
  public static func logError(_ error: SagaError) {
    #if canImport(os)
      Logger(subsystem: "swift-redux-saga", category: "Saga").error(
        """
        Unhandled error in saga \(error.sagaStack.joined(separator: " <- "), privacy: .public): \
        \(String(describing: error.underlying), privacy: .private)
        """
      )
    #else
      print("[Saga] Unhandled error in saga: \(error)")
    #endif
  }

  /// Host が処理した Action を Saga に届けます。
  ///
  /// その時点で `take` などで待っている Saga だけが受け取ります。
  ///
  /// ただし、最初の ``run(_:)`` から Saga がはじめて Effect（`take` など）で止まるまでの間に emit した Action は、
  /// 溜めておき、止まった時点で順に届けます。Saga は非同期に動き出すため、起動直後（View の表示時など）の
  /// Action を取りこぼさないようにするためです。
  public func emit(_ action: Action) {
    let isBuffered = startup.withLock { startup -> Bool in
      guard startup.isBuffering else { return false }
      startup.actions.append(action)
      return true
    }
    if !isBuffered {
      deliver(action)
    }
  }

  /// Action を、待っている Saga と、接続した子のランタイムに届ける。
  private func deliver(_ action: Action) {
    multicaster.emit(action)
    for scope in scopes.withLock({ Array($0.values) }) {
      scope.emit(action)
    }
  }

  /// Saga が、待つ Effect（`take` / `put` / `call` など）か終わりに達したことを記録する。
  ///
  /// 起動中に起動した Saga がすべて達したら、溜めた Action を届ける。redux-saga の `run` が、
  /// ルート Saga を最初の Effect まで同期に進めてから戻るのに合わせるため。
  func sagaDidReachEffect(_ id: SagaID) {
    let isReady = startup.withLock { startup -> Bool in
      guard startup.isBuffering, startup.pending.remove(id) != nil else { return false }
      return startup.pending.isEmpty
    }
    if isReady { deliverStartupActions() }
  }

  /// 起動中に溜めた Action を届け、溜めるのをやめる。
  ///
  /// 起動中の Saga がすべて最初の Effect に達したときのほか、すべての Saga が止まったときにも呼ぶ
  /// （チャネルの読み取りのように、Effect を通らずに待つ Saga があっても溜め続けないため）。
  private func deliverStartupActions() {
    let canDeliver = startup.withLock { startup -> Bool in
      guard startup.isBuffering, !startup.isDelivering else { return false }
      startup.isDelivering = true
      return true
    }
    guard canDeliver else { return }
    while true {
      // 届け終わるまで溜め続けるのは、届けている間に emit された Action が、溜めた Action より先に届かないようにするため。
      let actions = startup.withLock { startup -> [Action] in
        if startup.actions.isEmpty {
          startup.isBuffering = false
          startup.isDelivering = false
          startup.pending = []
        }
        defer { startup.actions = [] }
        return startup.actions
      }
      guard !actions.isEmpty else { return }
      for action in actions {
        deliver(action)
      }
    }
  }

  /// Saga を起動します。
  ///
  /// 起動した Saga は、呼び出し元のタスクとは独立して動きます。``stop()`` でまとめて止められます。
  /// 未処理のエラーで終わった場合は `onError` に渡されます。
  ///
  /// 最初の呼び出しから Saga がはじめて Effect で止まるまでに ``emit(_:)`` した Action は、止まった時点で届けます。
  @discardableResult
  public func run(_ saga: Saga<State, Action>) -> SagaTask {
    startup.withLock { startup in
      guard !startup.hasStarted else { return }
      startup.hasStarted = true
      startup.isBuffering = true
    }
    return start(saga)
  }

  /// Saga を根として起動する（`run` と `spawn`）。
  func start(_ saga: Saga<State, Action>) -> SagaTask {
    let state = makeTaskState(waitsForFirstEffect: true)
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

  /// すべての Saga が Effect（`take` / `join` / `delay` など）で止まるまで待ちます。
  ///
  /// テストで、Saga の処理が終わったことを確かめてから State を確認する場合などに使います。
  ///
  /// `call` で呼んだ関数が終わらない場合は、このメソッドも戻りません。
  public func waitUntilIdle() async {
    await activity.waitUntilIdle()
  }

  /// 起動したすべての Saga をキャンセルします。以降に ``run(_:)`` した Saga はすぐにキャンセルされます。
  /// 子のランタイムと共有する ID の連番。
  var nextIDSource: Locked<Int> {
    nextID
  }

  func makeScopeID() -> Int {
    nextScopeID.withLock { id in
      defer { id += 1 }
      return id
    }
  }

  var isStopped: Bool {
    rootTasks.withLock { $0.isStopped }
  }

  public func stop() {
    let tasks = rootTasks.withLock { rootTasks -> Set<SagaTask> in
      rootTasks.isStopped = true
      defer { rootTasks.tasks = [] }
      return rootTasks.tasks
    }
    for task in tasks {
      task.cancel()
    }
    for scope in scopes.withLock({ Array($0.values) }) {
      scope.stop()
    }
  }

  /// - Parameter waitsForFirstEffect: 起動中なら、この Saga が最初の Effect に達するまで Action を溜めるか。
  func makeTaskState(waitsForFirstEffect: Bool) -> SagaTaskState {
    let id = SagaID(
      rawValue: nextID.withLock { id in
        defer { id += 1 }
        return id
      })
    if waitsForFirstEffect {
      startup.withLock { startup in
        if startup.isBuffering { startup.pending.insert(id) }
      }
    }
    return SagaTaskState(id: id, activity: activity)
  }

  func finish(_ state: SagaTaskState, _ result: SagaResult) {
    sagaDidReachEffect(state.id)
    // join で待っている側より先にモニタに通知する。join から戻った時点で通知が終わっているようにするため。
    state.finish(result) {
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
        // 終わり方を確定する前に報告する。確定すると Activity の後始末の分が手放され、
        // settle() が報告より先に戻ってしまうため。
        onError(error)
        finish(state, .failed(error.underlying))
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
  ///
  /// `onFailure` を渡すと、失敗を親に伝えずに、元のエラーを `onFailure` に渡す（`all` / `race` が使う）。
  /// 子の終わり方を確定する前に呼ぶので、終わりを待っている側は渡したエラーを読める。
  func runForked(
    _ saga: Saga<State, Action>, state: SagaTaskState, parent: SagaTaskState,
    onFailure: (@Sendable (any Error) -> Void)? = nil
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
      } else if let onFailure {
        let underlying = (error as? SagaError)?.underlying ?? error
        onFailure(underlying)
        parent.childDidFinish(failed: false)
        finish(state, .failed(underlying))
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
