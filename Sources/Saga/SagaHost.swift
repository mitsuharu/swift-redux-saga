/// Saga が状態管理（Redux の Store など）とやり取りするための窓口。
///
/// Saga のコアは状態管理の具体型に依存せず、このプロトコルだけを通して動きます。
/// Action を Saga に届けるには、Action を処理した後に ``SagaRuntime/emit(_:)`` を呼んでください。
///
/// Redux の Store 用の実装は `ReduxSaga` モジュールの `SagaMiddleware` が提供します。
public protocol SagaHost<State, Action>: Sendable {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Action を発行します。Action の処理（reducer の適用）が終わってから戻ってください。
  func dispatch(_ action: Action) async

  /// 現在の State を返します。
  func state() async -> State
}
