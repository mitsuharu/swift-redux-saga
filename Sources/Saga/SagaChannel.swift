/// Saga が値を 1 つずつ受け取るチャネル。
///
/// ``SagaContext/actionChannel(_:buffer:)`` や ``SagaContext/eventChannel(buffer:_:)`` で作ります。
/// 複数の Saga から読むこともできます。その場合、値は待ち始めた順に 1 つずつ渡されます
/// （1 つのチャネルを複数のワーカーで処理する、redux-saga のワーカープールの書き方ができます）。
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
  ///
  /// `error` を渡すと、溜まっている値を受け取り終えた後の ``take()`` がそのエラーを 1 回投げます。
  public func close(throwing error: (any Error)? = nil) {
    core.close(throwing: error)
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
  /// `subscribe` には、値をチャネルに入れる関数 `emit` と、イベント源の終わりを伝える `finish` が渡されます。
  /// 障害で終わった場合は `finish(throwing: error)` を呼ぶと、受け取り側（`take` / `for try await`）が
  /// 溜まっている値を受け取り終えた後にそのエラーを投げます（正常終了と区別して、再接続などを書けます）。
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
      _ finish: EventChannelFinish
    ) -> @Sendable () -> Void
  ) -> SagaChannel<Value> {
    let channel = ChannelCore<Value>(buffer: buffer, activity: engine.activity)
    let unsubscribe = subscribe(
      { channel.put($0) }, EventChannelFinish { channel.close(throwing: $0) })
    channel.onClose(unsubscribe)
    closeWhenFinished(channel)
    return SagaChannel(core: channel)
  }

  /// AsyncSequence から値を受け取るチャネルを作ります。
  ///
  /// シーケンスが終わるとチャネルを閉じます。シーケンスがエラーで終わった場合は、受け取り側
  /// （`take` / `for try await`）が溜まっている値を受け取り終えた後にそのエラーを投げます。
  /// チャネルが閉じられると、シーケンスの読み取りをやめます。
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
          finish()
        } catch {
          // CancellationError も区別せずに伝える。チャネルが閉じられて読み取りをやめた場合は、
          // すでに閉じているので何も起きない。シーケンス自体が CancellationError で終わった場合は、
          // 伝えないとチャネルが開いたままになり、受け取り側が待ち続けるため。
          finish(throwing: error)
        }
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

/// ``SagaContext/eventChannel(buffer:_:)`` のイベント源が、終わりをチャネルに伝える関数。
public struct EventChannelFinish: Sendable {
  private let close: @Sendable ((any Error)?) -> Void

  init(_ close: @escaping @Sendable ((any Error)?) -> Void) {
    self.close = close
  }

  /// イベント源の終わりを伝えます。障害で終わった場合はエラーを渡します。
  ///
  /// - Parameter error: 終わった理由のエラー。正常終了なら `nil`。
  public func callAsFunction(throwing error: (any Error)? = nil) {
    close(error)
  }
}
