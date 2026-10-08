/// ネストした State のプロパティ単位で、Observation の追跡を行えるようにする型。
///
/// 自分で準拠させず、`ReduxMacros` の `@TrackedState` マクロを付けてください。マクロが各プロパティの
/// 読み取りを ``StateTrackingContext`` に知らせるコードを生成します。
///
/// `store.profile.name` のように Store から読んだ値（`profile`）の型が `TrackedState` だと、
/// `name` が変わったときだけ通知されます（準拠していなければ `profile` のどこが変わっても通知されます）。
public protocol TrackedState {
  /// 読み取りを知らせる先。マクロが生成します。直接使わないでください。
  var _$tracking: StateTrackingContext { get set }
}

/// ``TrackedState`` の値が、Store のどこから読まれたかを持つ。
///
/// 値の比較やハッシュには影響しません（常に等しい）。
public struct StateTrackingContext: Sendable, Hashable {
  /// Store の State から、この値までのキーパス。Store から読まれていない値では `nil`。
  let base: SendableKeyPath?
  /// 読み取ったキーパス（State から）を Store に知らせる。
  let access: @Sendable (SendableKeyPath) -> Void

  /// Store から読まれていない値の読み取り元（何も知らせない）。
  ///
  /// Optional にしないのは、Optional だと `==` で「読み取り元の有無」が比べられてしまうため。
  public init() {
    base = nil
    access = { _ in }
  }

  init(base: SendableKeyPath, access: @escaping @Sendable (SendableKeyPath) -> Void) {
    self.base = base
    self.access = access
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { true }
  public func hash(into hasher: inout Hasher) {}

  /// プロパティの読み取りを知らせて、値を返します。`@TrackedState` が生成したコードから呼ばれます。
  ///
  /// 値も ``TrackedState`` なら、知らせる代わりに読み取り元を引き継ぎ、その中のプロパティ単位で追跡します。
  public static func read<Root, Value>(
    _ value: Value, at keyPath: KeyPath<Root, Value>, in context: StateTrackingContext
  ) -> Value {
    guard let path = context.base?.appending(keyPath) else { return value }
    if var tracked = value as? any TrackedState {
      tracked._$tracking = StateTrackingContext(base: path, access: context.access)
      // `as?` で取り出した値は Value なので、元の型に戻せる。
      return tracked as? Value ?? value
    }
    context.access(path)
    return value
  }
}

/// `AnyKeyPath` を Sendable として持つための入れ物。
///
/// `@unchecked Sendable` にしているのは、キーパスのオブジェクトは作られた後に変更されないため。
/// 標準ライブラリで `AnyKeyPath` が Sendable でないのは、Sendable でない値を添字に持つキーパスがあり得るためで、
/// ここで扱うのは `& Sendable` のキーパスとプロパティだけをつないだキーパスに限られる。
struct SendableKeyPath: @unchecked Sendable, Hashable {
  let keyPath: AnyKeyPath

  init(_ keyPath: AnyKeyPath) {
    self.keyPath = keyPath
  }

  func appending(_ child: AnyKeyPath) -> SendableKeyPath? {
    keyPath.appending(path: child).map(SendableKeyPath.init)
  }
}
