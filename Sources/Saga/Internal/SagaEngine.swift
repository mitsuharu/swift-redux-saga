/// Saga を実行する仕組みのうち、ランタイムの State・Action に依存しない部分。
///
/// `SagaContext` はこれを通して子の起動や終わり方の確定を行う。State・Action に依存しないので、
/// 子の型に付け替えたコンテキスト（scope）からも、同じランタイムの仕組みをそのまま使える。
protocol SagaEngine: AnyObject, Sendable {
  var clock: any Clock<Duration> { get }
  var monitor: (any SagaMonitor)? { get }
  var activity: Activity { get }

  /// Saga の状態を作る。起動中なら、`waitsForFirstEffect` の Saga が最初の Effect に達するまで Action を溜める。
  func makeTaskState(waitsForFirstEffect: Bool) -> SagaTaskState

  /// Saga の終わり方を確定する。
  func finish(_ state: SagaTaskState, _ result: SagaResult)

  /// Saga が、待つ Effect か終わりに達したことを記録する（起動中の Action を溜める仕組みのため）。
  func sagaDidReachEffect(_ id: SagaID)

  /// 根まで伝わった未処理のエラーを報告する。
  func report(_ error: SagaError)

  /// Saga を根として起動する（`run` と `spawn`）。
  func start<State, Action>(
    _ saga: Saga<State, Action>, in environment: SagaEnvironment<State, Action>
  ) -> SagaTask
}

/// スコープに子の起動を要求する。
struct SagaForkRequest: Sendable {
  let run: @Sendable () async throws -> Void
}

extension SagaEngine {
  /// 根の Saga を実行し、終わり方を確定する。未処理のエラーは報告する。
  func runRoot<State, Action>(
    _ saga: Saga<State, Action>, in environment: SagaEnvironment<State, Action>,
    state: SagaTaskState
  ) async {
    do {
      try await runScoped(saga, in: environment, state: state)
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
        report(error)
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
  func runScoped<State, Action>(
    _ saga: Saga<State, Action>, in environment: SagaEnvironment<State, Action>,
    state: SagaTaskState
  ) async throws {
    let forks = ForkQueue<SagaForkRequest>()
    let context = SagaContext(engine: self, environment: environment, forks: forks, task: state)
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
  func runForked<State, Action>(
    _ saga: Saga<State, Action>, in environment: SagaEnvironment<State, Action>,
    state: SagaTaskState, parent: SagaTaskState,
    onFailure: (@Sendable (any Error) -> Void)?
  ) async throws {
    let signal = CancelSignal()
    state.onCancel { signal.fire() }
    do {
      try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
          try await self.runScoped(saga, in: environment, state: state)
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
}
