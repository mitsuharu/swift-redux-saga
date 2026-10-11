#if canImport(SwiftUI)
  import Observation
  import Redux
  import SwiftUI

  /// Environment の Store から値を読むプロパティラッパー（React Redux の `useSelector` 相当）。
  ///
  /// 親の View で ``SwiftUI/View/store(_:)`` を付けておくと、子の View は Store の型（Action の型）を書かずに、
  /// State から読む値だけを宣言できます。View は、読んだ値が変わったときだけ再描画されます。
  ///
  /// ```swift
  /// struct TodoListView: View {
  ///   @SelectState(\AppState.isLoading) private var isLoading
  ///   @SelectState(TodoFeature.visibleTodos) private var todos   // createSelector で作ったセレクタ
  ///
  ///   var body: some View { ... }
  /// }
  /// ```
  ///
  /// `store.isLoading` のように Store を直接読む書き方と違い、計算した値（セレクタ）でも、
  /// 計算結果が変わったときだけ再描画されます。
  // メインアクターに隔離しないのは、DynamicProperty の update() が隔離されていない要求で、
  // 隔離した型では準拠できないため。update() と値の読み取りはメインアクター上で呼ばれる（View の評価中）。
  @propertyWrapper
  public struct SelectState<State: Sendable, Value: Equatable>: DynamicProperty {
    @Environment(StoreSource<State>.self) private var source: StoreSource<State>?
    @SwiftUI.State private var selection = Selection<Value>()
    private let select: @MainActor (State) -> Value

    /// State のプロパティ（キーパス）を読みます。
    public init(_ keyPath: KeyPath<State, Value> & Sendable) {
      self.select = { $0[keyPath: keyPath] }
    }

    /// セレクタ（`createSelector` などで作ったもの）で読みます。
    public init(_ selector: Redux.Selector<State, Value>) where Value: Sendable {
      self.select = { selector($0) }
    }

    /// State から値を取り出す関数で読みます。
    public init(_ select: @escaping @MainActor (State) -> Value) {
      self.select = select
    }

    /// 読んだ値。
    @MainActor
    public var wrappedValue: Value {
      guard let value = selection.value else {
        preconditionFailure(
          "No Store<\(State.self), _> in the environment. Add .store(store) to an ancestor view.")
      }
      return value
    }

    public nonisolated func update() {
      // self ではなく、メインアクターに隔離された値だけを渡す（self は Sendable でないため）。
      let (source, selection, select) = (source, selection, select)
      MainActor.assumeIsolated {
        guard let source else { return }
        selection.connect(to: source, select: select)
      }
    }
  }

  /// Environment の Store に Action を送る関数を取り出すプロパティラッパー（React Redux の `useDispatch` 相当）。
  ///
  /// ```swift
  /// struct LoginView: View {
  ///   @DispatchAction private var dispatch: (AppAction) -> Void
  ///
  ///   var body: some View {
  ///     Button("Log in") { dispatch(.loginTapped) }
  ///   }
  /// }
  /// ```
  // メインアクターに隔離しない理由は SelectState と同じ。
  @propertyWrapper
  public struct DispatchAction<Action: Sendable>: DynamicProperty {
    @Environment(ActionSink<Action>.self) private var sink: ActionSink<Action>?

    public init() {}

    /// Store に Action を送る関数。
    @MainActor
    public var wrappedValue: (Action) -> Void {
      guard let sink else {
        preconditionFailure(
          "No Store<_, \(Action.self)> in the environment. Add .store(store) to an ancestor view.")
      }
      return sink.dispatch
    }
  }

  /// `SelectState` が読む Store を、Action の型を消して Environment に置くもの。
  @MainActor
  @Observable
  final class StoreSource<State: Sendable> {
    let id: ObjectIdentifier
    @ObservationIgnored let observe: (@escaping @MainActor (State) -> Void) -> ObservationToken

    init<Action>(_ store: Store<State, Action>) {
      id = ObjectIdentifier(store)
      observe = { [weak store] handler in
        guard let store else { return ObservationToken.observe({}, onChange: { _ in }) }
        return store.observe({ $0.state }, onChange: handler)
      }
    }
  }

  /// `DispatchAction` が送る先の Store を、State の型を消して Environment に置くもの。
  @MainActor
  @Observable
  final class ActionSink<Action: Sendable> {
    @ObservationIgnored let dispatch: (Action) -> Void

    init<State>(_ store: Store<State, Action>) {
      dispatch = { [weak store] in store?.dispatch($0) }
    }
  }

  /// `SelectState` が読んだ値を持ち、Store の変化で読み直す。値が変わったときだけ書き換えるので、
  /// View は計算結果が変わったときだけ再描画される。
  @MainActor
  @Observable
  final class Selection<Value: Equatable> {
    private(set) var value: Value?
    @ObservationIgnored private var sourceID: ObjectIdentifier?
    @ObservationIgnored private var token: ObservationToken?

    // SelectState の @State の初期値として、隔離されていない文脈で作るため。
    nonisolated init() {}

    func connect<State>(
      to source: StoreSource<State>, select: @escaping @MainActor (State) -> Value
    ) {
      // 同じ Store なら購読し直さない（update は body の評価のたびに呼ばれるため）。
      guard sourceID != source.id else { return }
      sourceID = source.id
      token = source.observe { [weak self] state in
        let newValue = select(state)
        // 変わったときだけ書き換える。書き換えないかぎり、この値を読む View は再描画されない。
        if self?.value != newValue { self?.value = newValue }
      }
    }
  }
#endif
