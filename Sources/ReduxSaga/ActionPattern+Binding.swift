import Redux
import Saga

extension ActionPattern where Action: BindableAction {
  /// `BindableState` を付けたプロパティを書き換える Action に一致し、新しい値を取り出すパターンを作ります。
  ///
  /// ```swift
  /// ctx.debounce(.milliseconds(300), .binding(\.$query)) { ctx, query in ... }
  /// ```
  public static func binding(
    _ keyPath: WritableKeyPath<Action.State, BindableState<Value>> & Sendable
  ) -> Self {
    Self { $0.binding?.value(for: keyPath) }
  }
}
