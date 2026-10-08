/// Saga が値を 1 つずつ受け取るチャネル。
///
/// ``SagaContext/actionChannel(_:buffer:)`` や ``SagaContext/eventChannel(buffer:_:)`` で作ります。
/// 受け取り側は 1 つの Saga だけにしてください。
///
/// 作った Saga が終わると、チャネルは自動で閉じます。
///
/// ```swift
/// let requests = ctx.actionChannel(.case { if case .request(let r) = $0 { r } else { nil } })
/// for try await request in requests {
///   try await handle(ctx, request)  // 1 件ずつ順に処理する
/// }
/// ```
public struct SagaChannel<Value: Sendable>: Sendable, AsyncSequence {
  let core: ChannelCore<Value>

  /// 次の値を待ちます。チャネルが閉じられ、溜まっている値もなくなったら `nil` を返します。
  ///
  /// - Throws: 待っている間にキャンセルされた場合は `CancellationError`。
  public func take() async throws -> Value? {
    try await core.take()
  }

  /// チャネルを閉じます。溜まっている値は引き続き受け取れます。
  public func close() {
    core.close()
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(core: core)
  }

  /// チャネルの値を順に取り出すイテレータ。
  public struct Iterator: AsyncIteratorProtocol {
    let core: ChannelCore<Value>

    public mutating func next() async throws -> Value? {
      try await core.take()
    }
  }
}

extension SagaContext {
  /// パターンに一致する Action を溜めるチャネルを作ります（redux-saga の `actionChannel`）。
  ///
  /// 作った時点から Action を溜め始めるので、処理中に届いた Action も取りこぼさずに 1 件ずつ順に処理できます。
  /// 作った Saga が終わると、チャネルは閉じて購読をやめます。
  ///
  /// - Parameters:
  ///   - pattern: 溜める Action のパターン。
  ///   - buffer: バッファの方式。既定は上限なし。
  public func actionChannel<Value>(
    _ pattern: ActionPattern<Action, Value>,
    buffer: ChannelBuffer = .unbounded
  ) -> SagaChannel<Value> {
    let channel = subscribe(pattern, buffer: buffer)
    closeWhenFinished(channel)
    return SagaChannel(core: channel)
  }

  /// 外部のイベント源から値を受け取るチャネルを作ります（redux-saga の `eventChannel`）。
  ///
  /// `subscribe` には、値をチャネルに入れる関数 `emit` と、イベント源の終わりを伝える関数 `finish` が渡されます。
  /// `subscribe` は購読を解除する関数を返してください。チャネルが閉じられたときに呼びます。
  /// 作った Saga が終わると、チャネルは閉じます。
  ///
  /// ```swift
  /// let ticks = ctx.eventChannel(buffer: .newest(1)) { emit, finish in
  ///   let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in emit(Date()) }
  ///   return { timer.invalidate() }
  /// }
  /// ```
  public func eventChannel<Value: Sendable>(
    buffer: ChannelBuffer = .unbounded,
    _ subscribe: (
      _ emit: @escaping @Sendable (Value) -> Void,
      _ finish: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void
  ) -> SagaChannel<Value> {
    let channel = ChannelCore<Value>(buffer: buffer, activity: runtime.activity)
    let unsubscribe = subscribe({ channel.put($0) }, { channel.close() })
    channel.onClose(unsubscribe)
    closeWhenFinished(channel)
    return SagaChannel(core: channel)
  }

  /// AsyncSequence から値を受け取るチャネルを作ります。
  ///
  /// シーケンスが終わるとチャネルを閉じます。チャネルが閉じられると、シーケンスの読み取りをやめます。
  /// シーケンスの読み取りは、チャネルが持つタスクで行います（Saga ではないため、`SagaTester` の `settle()` の対象外です）。
  public func eventChannel<Events: AsyncSequence & Sendable>(
    buffer: ChannelBuffer = .unbounded,
    from events: Events
  ) -> SagaChannel<Events.Element> where Events.Element: Sendable {
    eventChannel(buffer: buffer) { emit, finish in
      // 非構造化の Task を使うのは、外部のイベント源の寿命が Saga の木と一致しないため。
      // チャネルが閉じられたら（作った Saga が終わったら）キャンセルする。
      let task = Task {
        do {
          for try await event in events {
            emit(event)
          }
        } catch {}
        finish()
      }
      return { task.cancel() }
    }
  }

  private func closeWhenFinished<Value>(_ channel: ChannelCore<Value>) {
    if task.addObserver({ channel.close() }) == nil {
      channel.close()
    }
  }
}
