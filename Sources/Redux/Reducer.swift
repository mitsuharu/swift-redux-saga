/// State に Action を適用する、同期の純粋関数。
///
/// `inout` で State を直接書き換えます（Redux Toolkit が Immer で実現していることを言語機能で行います）。
///
/// ```swift
/// let counter = Reducer<Int, CounterAction> { state, action in
///   switch action {
///   case .increment: state += 1
///   case .decrement: state -= 1
///   }
/// }
/// ```
public struct Reducer<State: Sendable, Action: Sendable>: Sendable {
  private let body: @Sendable (inout State, Action) -> Void

  /// 関数から reducer を作ります。
  ///
  /// - Parameter reduce: State を書き換える関数。副作用（I/O、時刻の取得、乱数など）を持たせないでください。
  public init(_ reduce: @escaping @Sendable (inout State, Action) -> Void) {
    self.body = reduce
  }

  /// result builder で並べた reducer を、上から順に適用する reducer を作ります。
  ///
  /// ```swift
  /// let app = Reducer<AppState, AppAction> {
  ///   counterInApp
  ///   todosInApp
  /// }
  /// ```
  public init(@ReducerBuilder<State, Action> _ build: () -> Reducer) {
    self = build()
  }

  /// State に Action を適用します。
  public func reduce(into state: inout State, action: Action) {
    body(&state, action)
  }
}

extension Reducer {
  /// 何もしない reducer。
  public static var empty: Reducer {
    Reducer { _, _ in }
  }

  /// 複数の reducer を、引数の順に適用する reducer を作ります。
  public static func combine(_ reducers: Reducer...) -> Reducer {
    combine(reducers)
  }

  /// 複数の reducer を、配列の順に適用する reducer を作ります。
  public static func combine(_ reducers: [Reducer]) -> Reducer {
    Reducer { state, action in
      for reducer in reducers {
        reducer.reduce(into: &state, action: action)
      }
    }
  }

  /// 子の State と Action を扱う reducer を、親の State と Action に持ち上げます。
  ///
  /// ```swift
  /// Reducer<AppState, AppAction>.scope(
  ///   state: \.counter,
  ///   action: { if case .counter(let action) = $0 { action } else { nil } },
  ///   reducer: counterReducer
  /// )
  /// ```
  ///
  /// - Parameters:
  ///   - state: 親の State の中で、子の State がある場所。
  ///   - action: 親の Action から子の Action を取り出す関数。`nil` を返した Action は子に渡しません。
  ///   - reducer: 子の reducer。
  public static func scope<ChildState, ChildAction>(
    state: WritableKeyPath<State, ChildState> & Sendable,
    action: @escaping @Sendable (Action) -> ChildAction?,
    reducer: Reducer<ChildState, ChildAction>
  ) -> Reducer {
    Reducer { parentState, parentAction in
      guard let childAction = action(parentAction) else { return }
      reducer.reduce(into: &parentState[keyPath: state], action: childAction)
    }
  }
}

extension Reducer {
  /// 子の reducer を、親の State と Action に持ち上げます（Action をキーパスで取り出す版）。
  ///
  /// `ReduxMacros` の `@ActionCases` を親の Action に付けると、`action: \.counter` のように書けます。
  ///
  /// - Parameters:
  ///   - state: 親の State の中で、子の State がある場所。
  ///   - action: 親の Action から子の Action を取り出すキーパス。`nil` を返した Action は子に渡しません。
  ///   - reducer: 子の reducer。
  public static func scope<ChildState, ChildAction>(
    state: WritableKeyPath<State, ChildState> & Sendable,
    action: KeyPath<Action, ChildAction?> & Sendable,
    reducer: Reducer<ChildState, ChildAction>
  ) -> Reducer {
    scope(state: state, action: { $0[keyPath: action] }, reducer: reducer)
  }
}

/// 複数の reducer を宣言的に並べて、上から順に適用する reducer にまとめる result builder。
@resultBuilder
public enum ReducerBuilder<State: Sendable, Action: Sendable> {
  public static func buildExpression(_ reducer: Reducer<State, Action>) -> Reducer<State, Action> {
    reducer
  }

  public static func buildBlock(_ reducers: Reducer<State, Action>...) -> Reducer<State, Action> {
    .combine(reducers)
  }

  public static func buildOptional(_ reducer: Reducer<State, Action>?) -> Reducer<State, Action> {
    reducer ?? .empty
  }

  public static func buildEither(first reducer: Reducer<State, Action>) -> Reducer<State, Action> {
    reducer
  }

  public static func buildEither(second reducer: Reducer<State, Action>) -> Reducer<State, Action> {
    reducer
  }

  public static func buildArray(_ reducers: [Reducer<State, Action>]) -> Reducer<State, Action> {
    .combine(reducers)
  }
}
