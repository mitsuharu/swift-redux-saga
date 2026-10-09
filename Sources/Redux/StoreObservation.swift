import Observation

/// ``Store/observe(_:onChange:)`` の購読を表すトークン。
///
/// ``cancel()`` を呼ぶか、トークンを解放すると購読を解除します。
@MainActor
public final class ObservationToken {
  // 値を読み直してハンドラを呼ぶ処理。購読の関数（read / onChange）を持つのはトークンだけにして、
  // 解除したら手放す。Observation に登録するクロージャに持たせると、値が変わるまで残り、
  // ハンドラが捕捉したオブジェクトを解放できないため。
  private var update: (@MainActor (ObservationToken) -> Void)?

  init(update: @escaping @MainActor (ObservationToken) -> Void) {
    self.update = update
  }

  var isCancelled: Bool {
    update == nil
  }

  /// 購読を解除します。以降、ハンドラは呼ばれず、ハンドラが捕捉したオブジェクトも手放します。
  public func cancel() {
    update = nil
  }

  /// 値を読み直してハンドラを呼ぶ。解除されていれば何もしない。
  func fire() {
    update?(self)
  }

  /// `read` の中で読んだ値の変化を追跡し、値をハンドラに渡す。変化したら読み直す。
  func track<Value>(
    _ read: @MainActor () -> Value, onChange: @MainActor (Value) -> Void
  ) {
    let value = withObservationTracking(read) { [weak self] in
      // onChange は変更の直前（willSet）に呼ばれ、この時点では新しい値を読めない。
      // また、read の中で Store 以外の Observable を読んだ場合はメインアクター外から呼ばれ得るため、
      // その場で処理せず、変更後にメインアクターで読み直す。
      // トークンを弱参照にするのは、購読が呼び出し元やハンドラの捕捉したオブジェクトを延命しないため。
      Task { @MainActor in self?.fire() }
    }
    onChange(value)
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
    // Store を弱参照で持つのは、購読が Store を延命しないようにするため。
    let token = ObservationToken { [weak self] token in
      guard let self else {
        token.cancel()
        return
      }
      token.track({ read(self) }, onChange: onChange)
    }
    token.fire()
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
}

extension ObservationToken {
  /// `read` の中で読んだ Observable な値（ViewModel や Store）を、すぐに 1 回、その後は変わるたびに `onChange` に渡します。
  ///
  /// ``Store/observe(_:onChange:)`` と同じ仕組みで、Store 以外（MVVM の ViewModel など）にも使えます。
  /// UIKit で iOS 26 未満の OS に対応するときに使います。
  ///
  /// ```swift
  /// ObservationToken.observe { [weak viewModel] in viewModel?.todos ?? [] } onChange: { [weak self] todos in
  ///   self?.apply(todos)
  /// }
  /// .retained(by: self)
  /// ```
  ///
  /// `read` は購読が続く間保持されます。ViewModel などを強参照しないよう `[weak ...]` で読んでください。
  public static func observe<Value>(
    _ read: @escaping @MainActor () -> Value,
    onChange: @escaping @MainActor (Value) -> Void
  ) -> ObservationToken {
    let token = ObservationToken { token in
      token.track(read, onChange: onChange)
    }
    token.fire()
    return token
  }
}
