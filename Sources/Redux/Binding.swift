/// 入力欄（`TextField` や `Toggle` など）から直接書き換えてよい State のプロパティに付けるプロパティラッパー。
///
/// 印を付けたプロパティは、``BindingAction`` で値を書き換えられます。印のないプロパティは書き換えられません。
///
/// ```swift
/// struct State: Sendable, Equatable {
///   @BindableState var draft = ""
///   @BindableState var isNotificationOn = false
///   var todos: [Todo] = []
/// }
/// ```
///
/// プロパティの値は `state.draft` のように通常どおり読み書きできます。``BindingAction`` や SwiftUI の
/// `store.binding(\.$draft)` には、`$` を付けたキーパス（ラッパー自身）を渡します。
@propertyWrapper
public struct BindableState<Value> {
  public var wrappedValue: Value

  public init(wrappedValue: Value) {
    self.wrappedValue = wrappedValue
  }

  /// キーパス `\.$draft` でラッパー自身を指せるように、自身を返します。
  public var projectedValue: Self {
    get { self }
    set { self = newValue }
  }
}

extension BindableState: Sendable where Value: Sendable {}
extension BindableState: Equatable where Value: Equatable {}
extension BindableState: Hashable where Value: Hashable {}

/// ``BindableState`` を付けたプロパティを、新しい値に書き換える Action。
///
/// ``BindableAction`` に準拠した Action の `case binding(BindingAction<State>)` で使います。
public struct BindingAction<State: Sendable>: Sendable {
  /// 書き換えるプロパティ（ラッパー）のキーパス。
  public let keyPath: PartialKeyPath<State> & Sendable
  /// 書き換える値。
  public let value: any Sendable
  private let set: @Sendable (inout State) -> Void
  private let isEqualValue: @Sendable (any Sendable) -> Bool

  /// プロパティを `value` に書き換える Action を作ります。
  public static func set<Value: Equatable & Sendable>(
    _ keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable,
    _ value: Value
  ) -> Self {
    Self(
      keyPath: keyPath,
      value: value,
      set: { $0[keyPath: keyPath].wrappedValue = value },
      isEqualValue: { ($0 as? Value) == value }
    )
  }

  /// State に適用します。
  public func apply(to state: inout State) {
    set(&state)
  }

  /// このプロパティを書き換える Action なら、新しい値を返します。
  public func value<Value>(
    for keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable
  ) -> Value? {
    guard self.keyPath == keyPath as PartialKeyPath<State> else { return nil }
    return value as? Value
  }
}

extension BindingAction: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.keyPath == rhs.keyPath && lhs.isEqualValue(rhs.value)
  }
}

extension BindingAction: CustomStringConvertible {
  public var description: String {
    "set(\(keyPath), \(value))"
  }
}

/// ``BindingAction`` を case に持つ Action。
///
/// ```swift
/// enum Action: Sendable, BindableAction {
///   case binding(BindingAction<State>)
///   case addTapped
/// }
/// ```
///
/// `static func binding(_:)` は `case binding(BindingAction<State>)` で満たされます。
/// `var binding` は `ReduxMacros` の `@ActionCases`（`@Slice` の中の Action には自動で付く）が生成します。
/// マクロを使わない場合は `var binding: BindingAction<State>? { if case .binding(let b) = self { b } else { nil } }`
/// を書いてください。
public protocol BindableAction: Sendable {
  /// 書き換える State。
  associatedtype State: Sendable

  /// ``BindingAction`` を包んだ Action を作ります。
  static func binding(_ action: BindingAction<State>) -> Self

  /// ``BindingAction`` を包んだ Action なら、中身を返します。
  var binding: BindingAction<State>? { get }
}

extension Reducer where Action: BindableAction, Action.State == State {
  /// ``BindingAction`` を State に適用する reducer。ほかの reducer と並べて使います。
  ///
  /// ```swift
  /// let reducer = Reducer<State, Action> {
  ///   Reducer.binding
  ///   Reducer { state, action in ... }
  /// }
  /// ```
  public static var binding: Reducer {
    Reducer { state, action in
      action.binding?.apply(to: &state)
    }
  }
}
