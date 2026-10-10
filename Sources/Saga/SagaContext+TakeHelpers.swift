import InternalPrimitives

extension SagaContext {
  /// パターンに一致する Action を溜めるチャネルを作り、Action の購読を始める。
  ///
  /// 呼び出した時点で購読を始めるので、ヘルパーの子が動き出す前に届いた Action も取りこぼさない。
  func subscribe<Value>(
    _ pattern: ActionPattern<Action, Value>, buffer: ChannelBuffer
  ) -> ChannelCore<Value> {
    let channel = ChannelCore<Value>(buffer: buffer, activity: engine.activity)
    let unsubscribe = environment.actions.subscribe { action in
      if let value = pattern.match(action) { channel.put(value) }
    }
    channel.onClose(unsubscribe)
    return channel
  }

  /// チャネルから値を受け取るたびに `handle` を呼ぶ子を fork する。子が終わるとチャネルを閉じる。
  private func forkLoop<Value>(
    _ name: String,
    _ channel: ChannelCore<Value>,
    _ handle: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    let loop = Saga<State, Action>(name) { ctx in
      defer { channel.close() }
      while let value = try await channel.take() {
        try await handle(ctx, value)
      }
    }
    let task = fork(loop, in: environment, waitsForFirstEffect: false)
    // 呼び出し元が終わった後に fork された場合、子は動かないのでここで閉じる。
    if !task.isRunning { channel.close() }
    return task
  }

  /// パターンに一致する Action が届くたびに、`worker` を子として起動します（redux-saga の `takeEvery`）。
  ///
  /// 呼び出し元は待たずに続きを実行します。ワーカーは並行に動き、ワーカーの実行中に届いた Action も取りこぼしません。
  /// ワーカーが失敗すると、ヘルパーごと終了し、エラーが呼び出し元に伝わります。続けたい場合はワーカーの中で catch してください。
  ///
  /// ```swift
  /// ctx.takeEvery(.case { if case .fetch(let id) = $0 { id } else { nil } }) { ctx, id in
  ///   let user = try await ctx.call(fetchUser.execute, id)
  ///   await ctx.put(.fetched(user))
  /// }
  /// ```
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func takeEvery<Value>(
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    let channel = subscribe(pattern, buffer: .unbounded)
    return forkLoop("takeEvery", channel) { ctx, value in
      ctx.fork("takeEvery.worker") { try await worker($0, value) }
    }
  }

  /// パターンに一致する Action が届くたびに、実行中のワーカーをキャンセルしてから `worker` を起動します
  /// （redux-saga の `takeLatest`）。
  ///
  /// 検索の入力のように、最後のリクエストの結果だけが必要な場合に使います。
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func takeLatest<Value>(
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    let channel = subscribe(pattern, buffer: .unbounded)
    let latest = Locked<SagaTask?>(nil)
    return forkLoop("takeLatest", channel) { ctx, value in
      latest.withLock { $0 }?.cancel()
      let task = ctx.fork("takeLatest.worker") { try await worker($0, value) }
      latest.withLock { $0 = task }
    }
  }

  /// ワーカーが実行中でなければ `worker` を起動し、実行中に届いた Action は無視します（redux-saga の `takeLeading`）。
  ///
  /// 二重送信を防ぎたいボタンの処理などに使います。
  /// 登録直後の最初の Action も受け付け、ワーカーが動き出すまでの間の追加の Action は無視します。
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func takeLeading<Value>(
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    // 受け取った時点で実行枠を予約する。バッファなしだと、登録からヘルパーの待機開始までの Action を
    // 落とす。バッファだけを 1 件にすると、実行中の Action まで次の処理として溜めてしまう。
    let busy = Locked(false)
    let channel = ChannelCore<Value>(buffer: .oldest(1), activity: engine.activity)
    let unsubscribe = environment.actions.subscribe { action in
      guard let value = pattern.match(action) else { return }
      let accepted = busy.withLock { busy in
        guard !busy else { return false }
        busy = true
        return true
      }
      if accepted { channel.put(value) }
    }
    channel.onClose(unsubscribe)
    return forkLoop("takeLeading", channel) { ctx, value in
      defer { busy.withLock { $0 = false } }
      try await worker(ctx, value)
    }
  }

  /// パターンに一致する Action が `duration` のあいだ届かなくなってから、最後の Action で `worker` を起動します
  /// （redux-saga の `debounce`）。
  ///
  /// 文字入力のたびに届く Action を、入力が止まってから 1 回だけ処理したい場合に使います。
  /// 起動したワーカーは、その後に届いた Action ではキャンセルされません。
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func debounce<Value>(
    _ duration: Duration,
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    let channel = subscribe(pattern, buffer: .unbounded)
    let pending = Locked<SagaTask?>(nil)
    return forkLoop("debounce", channel) { helper, value in
      pending.withLock { $0 }?.cancel()
      // 待っている間に次の Action が来たら、この待機ごとキャンセルする。
      // ワーカーはヘルパーの子として起動し、後から来た Action の影響を受けないようにする。
      let timer = helper.fork("debounce.timer") { timer in
        try await timer.delay(duration)
        helper.fork("debounce.worker") { try await worker($0, value) }
      }
      pending.withLock { $0 = timer }
    }
  }

  /// パターンに一致する Action で `worker` を起動し、その後 `duration` のあいだに届いた Action は
  /// 最後の 1 つだけを残して捨てます（redux-saga の `throttle`）。
  ///
  /// 残った Action は、`duration` が過ぎた後にワーカーで処理します。スクロールなど頻繁に届く Action を
  /// 間引きたい場合に使います。
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func throttle<Value>(
    _ duration: Duration,
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    let channel = subscribe(pattern, buffer: .newest(1))
    return forkLoop("throttle", channel) { helper, value in
      helper.fork("throttle.worker") { try await worker($0, value) }
      try await helper.delay(duration)
    }
  }
}
