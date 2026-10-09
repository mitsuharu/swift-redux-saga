extension Store {
  /// reducer とミドルウェアを宣言的に並べて Store を作ります（Redux Toolkit の `configureStore` 相当）。
  ///
  /// ```swift
  /// let store = Store(initialState: AppState()) {
  ///   Reducer.slice(Counter.self, state: \.counter) { if case .counter(let a) = $0 { a } else { nil } }
  ///   Reducer.slice(Todos.self, state: \.todos) { if case .todos(let a) = $0 { a } else { nil } }
  /// } middleware: {
  ///   sagaMiddleware
  ///   if isDebug {
  ///     LoggingMiddleware()
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - initialState: State の初期値。
  ///   - reducer: 上から順に適用する reducer。
  ///   - middleware: 上から順に呼ぶミドルウェア。
  public convenience init(
    initialState: State,
    @ReducerBuilder<State, Action> reducer: () -> Reducer<State, Action>,
    @MiddlewareBuilder<State, Action> middleware: () -> [any Middleware<State, Action>] = { [] }
  ) {
    self.init(initialState: initialState, reducer: reducer(), middleware: middleware())
  }
}

/// ミドルウェアを宣言的に並べるための result builder。
@resultBuilder
public enum MiddlewareBuilder<State: Sendable, Action: Sendable> {
  public typealias Component = [any Middleware<State, Action>]

  public static func buildExpression(_ middleware: any Middleware<State, Action>) -> Component {
    [middleware]
  }

  public static func buildExpression(_ middleware: Component) -> Component {
    middleware
  }

  public static func buildBlock(_ components: Component...) -> Component {
    components.flatMap { $0 }
  }

  public static func buildOptional(_ component: Component?) -> Component {
    component ?? []
  }

  public static func buildEither(first component: Component) -> Component {
    component
  }

  public static func buildEither(second component: Component) -> Component {
    component
  }

  public static func buildArray(_ components: [Component]) -> Component {
    components.flatMap { $0 }
  }
}
