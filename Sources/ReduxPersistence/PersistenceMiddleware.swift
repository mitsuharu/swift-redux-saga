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
  private let hasChanged: (State, State) -> Bool
  private let debounce: Duration
  private let clock: any Clock<Duration>
  private let onError: @Sendable (any Error) -> Void
  private var pending: (task: Task<Void, Never>, isSuperseded: Locked<Bool>)?
  // 最後に作った保存の Task。保存を待っているかどうか（pending）とは別に持つのは、flush() で pending を
  // 外した後に作った保存も、書き込み中の保存の後に書くため。
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
    // スナップショットが Equatable なら、保存する部分が変わったときだけ保存する。
    // そうでなければ、State が変わるたびに保存する（debounce でまとめられる）。
    self.hasChanged = { old, new in
      let old = persistence.snapshot(of: old)
      let new = persistence.snapshot(of: new)
      guard let old = old as? any Equatable else { return true }
      return !old.isEqual(to: new)
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

extension Equatable {
  fileprivate func isEqual(to other: Any) -> Bool {
    guard let other = other as? Self else { return false }
    return self == other
  }
}
