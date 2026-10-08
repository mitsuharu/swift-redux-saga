import Observation

/// ``Store/observe(_:onChange:)`` の購読を表すトークン。
///
/// ``cancel()`` を呼ぶか、トークンを解放すると購読を解除します。
@MainActor
public final class ObservationToken {
  private(set) var isCancelled = false

  init() {}

  /// 購読を解除します。以降、ハンドラは呼ばれません。
  public func cancel() {
    isCancelled = true
  }
}

extension Store {
  /// `read` の中で読んだ値が変わるたびに `onChange` を呼びます。
  ///
  /// `onChange` は、呼び出した時点の値で 1 回すぐに呼ばれ、その後は値が変わるたびに呼ばれます。
  /// 変化の通知は、変更が終わった後にメインアクター上で非同期に届きます。続けて変更された場合は、
  /// 最後の値だけが届くことがあります。
  ///
  /// iOS 17 以降で動きます。UIKit で Observation の自動追跡を使えない場合や、
  /// ライフサイクルの外で購読したい場合に使います。
  ///
  /// ```swift
  /// token = store.observe { $0.count } onChange: { [weak self] count in
  ///   self?.label.text = "\(count)"
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - read: Store から値を読む関数。この中で読んだプロパティが追跡されます。
  ///   - onChange: 値を受け取る関数。
  /// - Returns: 購読のトークン。保持している間だけ購読が続きます。
  public func observe<Value>(
    _ read: @escaping @MainActor (Store) -> Value,
    onChange: @escaping @MainActor (Value) -> Void
  ) -> ObservationToken {
    let token = ObservationToken()
    Self.track(store: self, token: token, read: read, onChange: onChange)
    return token
  }

  /// `read` の中で読んだ値の変化を、AsyncSequence として受け取ります。
  ///
  /// 最初の要素は呼び出した時点の値です。受け取り側が遅れた場合は、最新の値だけを保持します。
  /// iteration をやめる（タスクがキャンセルされる）と購読を解除します。
  ///
  /// ```swift
  /// for await count in store.values({ $0.count }) {
  ///   print(count)
  /// }
  /// ```
  public func values<Value: Sendable>(
    _ read: @escaping @MainActor (Store) -> Value
  ) -> AsyncStream<Value> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Value.self, bufferingPolicy: .bufferingNewest(1))
    let token = observe(read) { continuation.yield($0) }
    continuation.onTermination = { _ in
      Task { @MainActor in token.cancel() }
    }
    return stream
  }

  // Store とトークンを弱参照で持つのは、購読が Store や呼び出し元を延命しないようにするため。
  private static func track<Value>(
    store: Store?,
    token: ObservationToken?,
    read: @escaping @MainActor (Store) -> Value,
    onChange: @escaping @MainActor (Value) -> Void
  ) {
    guard let store, let token, !token.isCancelled else { return }
    let value = withObservationTracking {
      read(store)
    } onChange: { [weak store, weak token] in
      // onChange は変更の直前（willSet）に呼ばれ、この時点では新しい値を読めない。
      // また、read の中で Store 以外の Observable を読んだ場合はメインアクター外から呼ばれ得るため、
      // その場で処理せず、変更後にメインアクターで読み直す。
      Task { @MainActor in
        track(store: store, token: token, read: read, onChange: onChange)
      }
    }
    onChange(value)
  }
}
