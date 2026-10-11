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
    @ObservationIgnored let observe: (@escaping @MainActor () -> Void) -> ObservationToken
    @ObservationIgnored let currentState: () -> State?

    init<Action>(_ store: Store<State, Action>) {
      id = ObjectIdentifier(store)
      observe = { [weak store] handler in
        guard let store else { return ObservationToken.observe({}, onChange: { _ in }) }
        return store.observe({ $0.state }, onChange: { _ in handler() })
      }
      // 追跡に登録せずに読む。View の評価中（update()）に読むので、追跡すると View が State 全体の変化で
      // 再描画されるようになり、セレクタの結果で再描画を絞れなくなるため。
      currentState = { [weak store] in store?.untrackedState }
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
    // 今の Store とセレクタで値を読み直す関数。connect のたびに差し替える。
    @ObservationIgnored private var reselect: (@MainActor () -> Value?)?

    // SelectState の @State の初期値として、隔離されていない文脈で作るため。
    nonisolated init() {}

    /// Store とセレクタを設定し、今の値を読み直す。`update()` から、View の評価のたびに呼ばれる。
    func connect<State>(
      to source: StoreSource<State>, select: @escaping @MainActor (State) -> Value
    ) {
      // セレクタは毎回差し替えて読み直す。SwiftUI が View の状態を保ったまま、表示する対象（ID など）を
      // 変えた場合に、新しいセレクタを反映するため（クロージャは比較できないので、変わったかを判定しない）。
      reselect = { source.currentState().map(select) }
      refresh()
      // 購読は Store が変わったときだけし直す。購読の通知では、その時点のセレクタで読み直す。
      guard sourceID != source.id else { return }
      sourceID = source.id
      token?.cancel()
      token = nil
      // 購読は View の評価（update()）の外で始める。Observation は入れ子の追跡で読んだ値も外側の追跡に
      // 含めるため、View の評価中に購読を始めると、View が State 全体を追跡し、関係のない変更でも
      // 再描画されるようになる。間に起きた変更は、購読を始めた時点の読み直しで反映される。
      let id = source.id
      Task { @MainActor [weak self] in
        guard let self, sourceID == id, token == nil else { return }
        token = source.observe { [weak self] in self?.refresh() }
      }
    }

    private func refresh() {
      guard let newValue = reselect?() else { return }
      // 変わったときだけ書き換える。書き換えないかぎり、この値を読む View は再描画されない。
      if value != newValue { value = newValue }
    }
  }
#endif
