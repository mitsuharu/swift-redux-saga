import Redux

/// enum の case ごとに、「その case なら関連値を返し、そうでなければ `nil` を返す」プロパティを生成します。
///
/// 生成されたプロパティのキーパスで、Saga のパターンや reducer の scope を短く書けます。
///
/// ```swift
/// @ActionCases
/// enum AppAction: Sendable {
///   case counter(CounterAction)
///   case toggleTapped(Todo.ID)
///   case reset
/// }
///
/// // 生成されるプロパティ
/// // var counter: CounterAction? { ... }
/// // var toggleTapped: Todo.ID? { ... }
/// // var reset: Void? { ... }
///
/// let id = try await ctx.take(.case(\.toggleTapped))
/// Reducer.slice(Counter.self, state: \.counter, action: \.counter)
/// ```
///
/// 関連値が複数ある case は、ラベル付きのタプルを返します（`case add(id: Int, title: String)` なら
/// `(id: Int, title: String)?`）。関連値のない case は `Void?` を返します。
@attached(member, names: arbitrary)
public macro ActionCases() = #externalMacro(module: "ReduxMacrosPlugin", type: "ActionCasesMacro")

/// enum を ``Redux/Slice`` にします。
///
/// - `Slice` への準拠を追加します。
/// - `initialState` がなければ `static let initialState = State()` を追加します。
/// - 中の `enum Action` に `@ActionCases` を付けます。
///
/// ```swift
/// @Slice
/// enum Counter {
///   struct State: Sendable, Equatable { var count = 0 }
///   enum Action: Sendable { case increment, add(Int) }
///
///   static func reduce(into state: inout State, action: Action) { ... }
/// }
/// ```
///
/// default MainActor isolation を有効にしたモジュールでは、`@Slice nonisolated enum Counter` と書いてください。
@attached(extension, conformances: Slice)
@attached(member, names: named(initialState))
@attached(memberAttribute)
public macro Slice() = #externalMacro(module: "ReduxMacrosPlugin", type: "SliceMacro")
