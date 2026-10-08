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

/// enum を `Slice` にします。
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

/// struct のプロパティ単位で、Observation の追跡を行えるようにします。
///
/// State の中にネストした struct に付けると、`store.profile.name` のように読んだとき、
/// `profile` のほかのプロパティが変わっても通知されず、`name` が変わったときだけ通知されます。
///
/// ```swift
/// @TrackedState
/// struct Profile: Sendable, Equatable {
///   var name: String = ""
///   var age: Int = 0
/// }
/// ```
///
/// - 対象は型を書いた `var` の保存プロパティです。計算プロパティは、中で読んだ保存プロパティが追跡されます。
/// - `let` やプロパティラッパー付き（`@BindableState` など）のプロパティは追跡の仕組みを入れられないため、
///   それらを含む型の値は、値全体が変わったときに通知します（通知の漏れはありませんが、細かくはなりません）。
/// - `Codable` の自動準拠を使う場合、キーが `_name` になる点に注意してください（`CodingKeys` を書いてください）。
/// - 値全体を比較したり受け渡したりするだけでは追跡されません。読んだプロパティだけが追跡されます。
@attached(member, names: named(_$tracking), named(_$hasUntrackedProperties))
@attached(extension, conformances: TrackedState)
@attached(memberAttribute)
public macro TrackedState() =
  #externalMacro(module: "ReduxMacrosPlugin", type: "TrackedStateMacro")

/// `@TrackedState` がプロパティに付けるマクロ。直接使わないでください。
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_))
public macro TrackedProperty() =
  #externalMacro(module: "ReduxMacrosPlugin", type: "TrackedPropertyMacro")
