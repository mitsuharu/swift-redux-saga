import Observation

/// テストから値を書き換えるための入れ物。
@MainActor
final class Box<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// `withObservationTracking` の onChange を MainActor 上の処理として書くためのヘルパー。
///
/// Store の変更はメインアクター上で行われ、onChange は変更したスレッドで同期に呼ばれるため、
/// `assumeIsolated` が成り立つ。
@MainActor
func track(_ read: () -> Void, onChange: @escaping @MainActor () -> Void) {
  withObservationTracking(read) {
    MainActor.assumeIsolated(onChange)
  }
}
