/// Saga の木の根まで伝わった、未処理のエラー。
///
/// ``SagaRuntime`` の `onError` に渡されます。
public struct SagaError: Error {
  /// 元のエラー。
  public let underlying: any Error

  /// エラーが伝わった Saga の経路。エラーが起きた Saga から根に向かう順に並びます。
  ///
  /// 名前のない Saga は `"anonymous"` になります。
  public let sagaStack: [String]

  /// 経路に Saga を 1 つ足したエラーを返す。
  static func propagating(_ error: any Error, through saga: String?) -> SagaError {
    let name = saga ?? "anonymous"
    if let error = error as? SagaError {
      return SagaError(underlying: error.underlying, sagaStack: error.sagaStack + [name])
    }
    return SagaError(underlying: error, sagaStack: [name])
  }
}

extension SagaError: CustomStringConvertible {
  public var description: String {
    "\(underlying) (saga: \(sagaStack.joined(separator: " <- ")))"
  }
}
