/// Saga の識別子。ランタイムの中で一意です。
public struct SagaID: Sendable, Hashable, CustomStringConvertible {
  let rawValue: Int

  public var description: String {
    "#\(rawValue)"
  }
}

/// Saga の終わり方。
public enum SagaResult: Sendable {
  case completed
  case cancelled
  case failed(any Error)
}

/// モニタに通知される Effect。
public enum SagaEffect: Sendable {
  case take
  /// 発行した Action の説明（`String(describing:)`）。
  case put(String)
  case select
  case call
  case fork(SagaID)
  case spawn(SagaID)
  case join(SagaID)
  case cancel(SagaID)
  case delay(Duration)
}

/// Saga の起動・終了・Effect を受け取るフック。ログ出力やデバッグ用です。
///
/// メソッドは Saga を実行しているタスクから同期に呼ばれます。重い処理をしないでください。
/// 実装しないメソッドは何もしません。
public protocol SagaMonitor: Sendable {
  /// Saga が起動されたときに呼ばれます。`parent` は fork 元（根や spawn の場合は `nil`）です。
  func sagaStarted(_ id: SagaID, name: String?, parent: SagaID?)

  /// Saga が終わったときに呼ばれます。
  func sagaFinished(_ id: SagaID, result: SagaResult)

  /// Saga が Effect を呼んだときに呼ばれます。
  func effectTriggered(_ id: SagaID, effect: SagaEffect)
}

extension SagaMonitor {
  public func sagaStarted(_ id: SagaID, name: String?, parent: SagaID?) {}
  public func sagaFinished(_ id: SagaID, result: SagaResult) {}
  public func effectTriggered(_ id: SagaID, effect: SagaEffect) {}
}
