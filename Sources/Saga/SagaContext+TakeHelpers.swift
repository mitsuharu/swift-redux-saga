import InternalPrimitives

extension SagaContext {
  /// パターンに一致する Action を溜めるチャネルを作り、Action の購読を始める。
  ///
  /// 呼び出した時点で購読を始めるので、ヘルパーの子が動き出す前に届いた Action も取りこぼさない。
  func subscribe<Value>(
    _ pattern: ActionPattern<Action, Value>, buffer: ChannelBuffer
  ) -> ChannelCore<Value> {
    let channel = ChannelCore<Value>(buffer: buffer, activity: runtime.activity)
    let unsubscribe = runtime.multicaster.subscribe { action in
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
    let task = fork(name) { ctx in
      defer { channel.close() }
      while let value = try await channel.take() {
        try await handle(ctx, value)
      }
    }
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
  ///
  /// - Returns: ヘルパーのハンドル。キャンセルするとワーカーも止まります。
  @discardableResult
  public func takeLeading<Value>(
    _ pattern: ActionPattern<Action, Value>,
    _ worker: @escaping @Sendable (SagaContext, Value) async throws -> Void
  ) -> SagaTask {
    // 実行中の Action を溜めないよう、バッファを持たないチャネルにする（受け取り側が待っているときだけ渡る）。
    let channel = subscribe(pattern, buffer: .oldest(0))
    return forkLoop("takeLeading", channel) { ctx, value in
      // fork せずにその場で実行する。実行中はチャネルを待っていないので、届いた Action は捨てられる。
      try await worker(ctx, value)
    }
  }
}
