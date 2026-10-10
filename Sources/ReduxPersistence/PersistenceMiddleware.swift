import InternalPrimitives
import Redux

/// State が変わったら、少し待ってまとめて保存するミドルウェア。
///
/// 続けて変わった場合は、最後に変わってから `debounce` だけ経ったときに 1 回保存します。
/// 保存（エンコードと書き込み）はメインアクターの外で行います。
///
/// アプリがバックグラウンドに入るときなど、すぐに保存したい場合は ``flush()`` を呼んでください。
@MainActor
public final class PersistenceMiddleware<State: Sendable, Action: Sendable>: Middleware {
  private let save: @Sendable (State) throws -> Void
  private let remove: @Sendable () throws -> Void
  private let hasChanged: (State, State) -> Bool
  private let debounce: Duration
  private let clock: any Clock<Duration>
  private let onError: @Sendable (any Error) -> Void
  private var pending: (task: Task<Void, Never>, isSuperseded: Locked<Bool>)?
  // 最後に作った保存・削除の完了を待つ Task。pending と別に持つのは、flush() / clear() が
  // 待っている間に新しく予約された保存も、それまでの書き込み・削除の後に実行するため。
  private var lastSave: Task<Void, Never>?

  /// ミドルウェアを作ります。
  ///
  /// - Parameters:
  ///   - persistence: 保存の設定。
  ///   - debounce: 最後に変わってから保存するまでの時間。
  ///   - clock: 待つための時計。テストでは `TestClock` を渡します。
  ///   - onError: 保存に失敗したときに呼ぶ関数（ログ出力など）。
  public init<Snapshot>(
    _ persistence: Persistence<State, Snapshot>,
    debounce: Duration = .milliseconds(500),
    clock: any Clock<Duration> = ContinuousClock(),
    onError: @escaping @Sendable (any Error) -> Void = { _ in }
  ) {
    self.save = { try persistence.save($0) }
    self.remove = { try persistence.clear() }
    // スナップショットが Equatable なら、保存する部分が変わったときだけ保存する。
    // そうでなければ、State が変わるたびに保存する（debounce でまとめられる）。
    self.hasChanged = { old, new in
      !isEqualIfEquatable(persistence.snapshot(of: old), persistence.snapshot(of: new))
    }
    self.debounce = debounce
    self.clock = clock
    self.onError = onError
  }

  public func handle(
    _ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void
  ) {
    let oldState = store.state
    next(action)
    let newState = store.state
    guard hasChanged(oldState, newState) else { return }
    schedule(newState)
  }

  /// 保存を待っている State があれば、すぐに保存します。書き込み中の保存があれば、その終わりも待ちます。
  public func flush() async {
    if let pending {
      self.pending = nil
      pending.task.cancel()
    }
    // 保存はそれぞれ前の保存の後に書くので、最後の保存を待てば、それまでの保存はすべて終わっている。
    await lastSave?.value
  }

  /// 保存したデータを消します。保存を待っている State は保存せず、書き込み中の保存が終わってから消します。
  ///
  /// ログアウトなどで保存したデータを消すときは、`Persistence.clear()` ではなくこのメソッドを使ってください。
  /// `Persistence.clear()` で直接消すと、保存を待っていた State が後から書かれ、消したデータが戻ります。
  /// この呼び出しが待っている間に予約された保存は、削除が終わってから実行します。
  /// 削除はメインアクターの外で行い、失敗した場合はそのエラーを投げます。
  public func clear() async throws {
    if let pending {
      self.pending = nil
      pending.isSuperseded.withLock { $0 = true }
      pending.task.cancel()
    }
    let previous = lastSave
    let remove = remove
    let removal = Task.detached {
      await previous?.value
      try remove()
    }
    // await の前に後続処理の待機先を置く。呼び出し元だけが前の保存を待つと、その間に
    // 予約された新しい保存が削除より先に完了し、新しいデータまで消してしまうため。
    // 失敗は clear の呼び出し元へ返し、後続の保存・削除には伝播させない。
    lastSave = Task.detached { _ = await removal.result }
    try await removal.value
  }

  private func schedule(_ state: State) {
    if let pending {
      // 新しい State で保存し直すので、古い方は保存しない。
      pending.isSuperseded.withLock { $0 = true }
      pending.task.cancel()
    }
    let isSuperseded = Locked(false)
    let previous = lastSave
    let (save, clock, debounce, onError) = (save, clock, debounce, onError)
    // Task.detached にするのは、エンコードとファイルへの書き込みをメインアクターで行わないため。
    let task = Task.detached {
      // flush() でキャンセルされた場合は、待たずにすぐ保存する。
      try? await clock.sleep(for: debounce)
      // 前の保存が書き込み中なら終わるのを待つ。待たずに書くと、前の（古い）State が後から書かれて残り得る。
      // 新しい保存に置き換えられた場合も待ってから戻るのは、次の保存が前の書き込みを待てるようにするため。
      await previous?.value
      guard !isSuperseded.withLock({ $0 }) else { return }
      do {
        try save(state)
      } catch {
        onError(error)
      }
    }
    pending = (task, isSuperseded)
    lastSave = task
  }
}
