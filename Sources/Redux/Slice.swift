/// State・Action・reducer を 1 つにまとめた機能の単位（Redux Toolkit の `createSlice` 相当）。
///
/// Swift では enum の case が Action を作る関数の役割を果たすため、Slice は State と Action の型と、
/// reducer をまとめる名前空間として定義します。
///
/// ```swift
/// enum Counter: Slice {
///   struct State: Sendable, Equatable { var count = 0 }
///   enum Action: Sendable { case increment, decrement, add(Int) }
///
///   static let initialState = State()
///
///   static func reduce(into state: inout State, action: Action) {
///     switch action {
///     case .increment: state.count += 1
///     case .decrement: state.count -= 1
///     case .add(let value): state.count += value
///     }
///   }
/// }
/// ```
///
/// default MainActor isolation を有効にしたモジュールでは、`nonisolated enum Counter: Slice` と宣言してください
/// （reducer はメインアクター外からも呼ばれるため）。
// SendableMetatype を要求するのは、reducer（@Sendable）の中から Slice の static func を呼ぶため。
// メインアクターに隔離された準拠では、メインアクター外から reduce を呼べない。
public protocol Slice: SendableMetatype {
  /// この機能の State。
  associatedtype State: Sendable
  /// この機能の Action。
  associatedtype Action: Sendable

  /// State の初期値。
  static var initialState: State { get }

  /// State に Action を適用します。副作用を持たせないでください。
  static func reduce(into state: inout State, action: Action)
}

extension Slice {
  /// この Slice の reducer。
  public static var reducer: Reducer<State, Action> {
    Reducer { state, action in reduce(into: &state, action: action) }
  }
}

extension Reducer {
  /// Slice の reducer を、親の State と Action に持ち上げます。
  ///
  /// ```swift
  /// let app = Reducer<AppState, AppAction> {
  ///   Reducer.slice(Counter.self, state: \.counter) {
  ///     if case .counter(let action) = $0 { action } else { nil }
  ///   }
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - slice: 持ち上げる Slice。
  ///   - state: 親の State の中で、Slice の State がある場所。
  ///   - action: 親の Action から Slice の Action を取り出す関数。
  public static func slice<S: Slice>(
    _ slice: S.Type,
    state: WritableKeyPath<State, S.State> & Sendable,
    action: @escaping @Sendable (Action) -> S.Action?
  ) -> Reducer {
    scope(state: state, action: action, reducer: S.reducer)
  }
}
