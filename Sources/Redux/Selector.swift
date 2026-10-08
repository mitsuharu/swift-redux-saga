import InternalPrimitives

/// State から値を取り出す関数（Redux Toolkit の `createSelector` で作るセレクタ相当）。
///
/// ``createSelector(_:result:)`` で作ると、入力が前回と同じときは前回の結果を返します（メモ化）。
/// 関数として呼び出せます。
///
/// ```swift
/// let visibleTodos = createSelector(\AppState.todos, \.filter) { todos, filter in
///   todos.filter(filter.matches)
/// }
/// let todos = visibleTodos(store.state)
/// // Saga の中では
/// let todos = await ctx.select { visibleTodos($0) }
/// ```
public struct Selector<State: Sendable, Output: Sendable>: Sendable {
  private let select: @Sendable (State) -> Output

  /// 関数からセレクタを作ります（メモ化しません）。
  public init(_ select: @escaping @Sendable (State) -> Output) {
    self.select = select
  }

  /// State から値を取り出します。
  public func callAsFunction(_ state: State) -> Output {
    select(state)
  }
}

/// 入力セレクタの結果が前回と同じなら、前回の結果を返すセレクタを作ります（Redux Toolkit の `createSelector`）。
///
/// 入力セレクタは任意の個数を渡せます。`result` は入力が変わったときだけ呼ばれます。
/// キーパス（`\AppState.todos`）も渡せます。クロージャで渡す場合、State の型を推論できるように
/// 最初の引数の型を書くか（`{ (state: AppState) in state.todos }`）、戻り値の型を書いてください。
/// キャッシュは直近の 1 件だけで、メインアクター外（Saga）から呼んでも安全です。
///
/// - Parameters:
///   - inputs: State から入力を取り出す関数。結果は `Equatable` であること。
///   - result: 入力から結果を計算する関数。
public func createSelector<State: Sendable, each Input: Equatable & Sendable, Output: Sendable>(
  _ inputs: repeat @escaping @Sendable (State) -> each Input,
  result: @escaping @Sendable (repeat each Input) -> Output
) -> Selector<State, Output> {
  let cache = Locked<Memo<Output>?>(nil)
  return Selector { state in
    let current = (repeat (each inputs)(state))
    var collected: [EquatableKey] = []
    for input in repeat each current {
      collected.append(EquatableKey(input))
    }
    let keys = collected
    if let memo = cache.withLock({ $0 }), memo.inputs == keys {
      return memo.output
    }
    // 結果の計算はロックの外で行う（利用者のコードをロックの中で呼ばないため）。
    let output = result(repeat each current)
    cache.withLock { $0 = Memo(inputs: keys, output: output) }
    return output
  }
}

// 入力をパラメータパックのまま保持しないのは、パックを持つジェネリック型の保存で
// Swift 6.3 のコンパイラがクラッシュするため。型を消した配列にして比較する。
private struct Memo<Output: Sendable>: Sendable {
  let inputs: [EquatableKey]
  let output: Output
}

/// 型を消した Equatable な値。同じ型で、値が等しいときだけ等しい。
private struct EquatableKey: Equatable, Sendable {
  private let value: any Equatable & Sendable
  private let isEqualTo: @Sendable (any Equatable & Sendable) -> Bool

  init<Value: Equatable & Sendable>(_ value: Value) {
    self.value = value
    self.isEqualTo = { ($0 as? Value) == value }
  }

  static func == (lhs: EquatableKey, rhs: EquatableKey) -> Bool {
    lhs.isEqualTo(rhs.value)
  }
}
