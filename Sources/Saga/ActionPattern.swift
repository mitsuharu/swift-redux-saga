/// Action が一致するかを判定し、一致したら値を取り出すパターン。
///
/// `take` などの Effect に渡し、一致した Action から取り出した `Value` を受け取ります。
///
/// ```swift
/// // enum の case から関連値を取り出す
/// let fetch = ActionPattern<AppAction, User.ID>.case {
///   if case .user(.fetch(let id)) = $0 { id } else { nil }
/// }
/// let id = try await ctx.take(fetch)
///
/// // Action そのものを受け取る
/// let action = try await ctx.take(.filter { $0.isUserAction })
/// ```
public struct ActionPattern<Action: Sendable, Value: Sendable>: Sendable {
  private let extract: @Sendable (Action) -> Value?

  /// 一致したら値を返し、一致しなければ `nil` を返す関数からパターンを作ります。
  ///
  /// 関数は純粋にしてください（Action を配信するたびに、ロックの中で呼ばれます）。
  public init(_ extract: @escaping @Sendable (Action) -> Value?) {
    self.extract = extract
  }

  /// enum の case などから値を型付きで取り出すパターンを作ります。``init(_:)`` と同じです。
  public static func `case`(_ extract: @escaping @Sendable (Action) -> Value?) -> Self {
    Self(extract)
  }

  /// Action のプロパティ（キーパス）が値を返したら一致するパターンを作ります。
  ///
  /// `ReduxMacros` の `@ActionCases` を enum に付けると、case ごとに「その case なら関連値を返し、
  /// そうでなければ `nil` を返す」プロパティが生成されるので、次のように書けます。
  ///
  /// ```swift
  /// let id = try await ctx.take(.case(\.toggleTapped))
  /// let query = try await ctx.take(.case(\.user?.search))   // ネストした enum
  /// ```
  public static func `case`(_ keyPath: KeyPath<Action, Value?> & Sendable) -> Self {
    Self { $0[keyPath: keyPath] }
  }

  /// 型で判定するパターンを作ります。
  ///
  /// `Action` がプロトコル存在型（`any AppAction` など）で、Action ごとに型を分けている場合に使います。
  ///
  /// ```swift
  /// let request = try await ctx.take(.type(FetchUser.self))
  /// ```
  public static func type(_ type: Value.Type) -> Self {
    Self { $0 as? Value }
  }

  /// いずれかのパターンに一致するパターンを作ります。先に書いたパターンが優先されます。
  public static func oneOf(_ patterns: Self...) -> Self {
    Self { action in
      for pattern in patterns {
        if let value = pattern.match(action) { return value }
      }
      return nil
    }
  }

  /// Action が一致すれば取り出した値を、一致しなければ `nil` を返します。
  public func match(_ action: Action) -> Value? {
    extract(action)
  }

  /// 取り出した値が条件を満たす場合だけ一致するパターンを作ります。
  public func `where`(_ predicate: @escaping @Sendable (Value) -> Bool) -> Self {
    Self { action in
      guard let value = extract(action), predicate(value) else { return nil }
      return value
    }
  }
}

extension ActionPattern where Value == Action {
  /// すべての Action に一致するパターン。
  public static var any: Self {
    Self { $0 }
  }

  /// 条件を満たす Action に一致するパターンを作ります。
  public static func filter(_ predicate: @escaping @Sendable (Action) -> Bool) -> Self {
    Self { predicate($0) ? $0 : nil }
  }
}

extension ActionPattern where Value == Action, Action: Equatable {
  /// 指定した Action と等しい Action に一致するパターンを作ります。
  ///
  /// ```swift
  /// try await ctx.take(.action(.logout))
  /// ```
  public static func action(_ expected: Action) -> Self {
    Self { $0 == expected ? $0 : nil }
  }
}
