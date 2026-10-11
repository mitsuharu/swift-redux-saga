#if canImport(SwiftUI)
  import Observation
  import Redux
  import SwiftUI

  /// Environment の Store から値を読むプロパティラッパー（React Redux の `useSelector` 相当）。
  ///
  /// 親の View で `.store(_:)` を付けておくと、子の View は Store の型（Action の型）を書かずに、
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
  ///
  /// `.store(_:)` を入れ子にした場合は、State の型が一致する Store のうち、最も近い（内側の）ものを読みます。
  /// ``DispatchAction`` は Action の型で別に探すので、両者が同じ Store を指すとは限りません。
  /// 使う Store を明示したいときは、`.store(_:id:)` で付けた識別子を `store:` で渡します。
  ///
  /// 再描画は結果が変わったときだけですが、セレクタは State が変わるたびと View の評価のたびに呼ばれます。
  /// 重い計算は、入力を絞った `createSelector` のセレクタを `static let` などで一度だけ作って渡してください。
  // メインアクターに隔離しないのは、DynamicProperty の update() が隔離されていない要求で、
  // 隔離した型では準拠できないため。update() と値の読み取りはメインアクター上で呼ばれる（View の評価中）。
  @propertyWrapper
  public struct SelectState<State: Sendable, Value: Equatable>: DynamicProperty {
    @Environment(StoreSource<State>.self) private var source: StoreSource<State>?
    @Environment(\.namedStores) private var namedStores
    @SwiftUI.State private var selection = Selection<Value>()
    private let select: @MainActor (State) -> Value
    private let storeID: StoreID?

    /// State のプロパティ（キーパス）を読みます。
    ///
    /// - Parameters:
    ///   - keyPath: 読むプロパティ。
    ///   - id: 読む Store の識別子（`.store(_:id:)` で付けたもの）。`nil` なら、State の型が一致する最も近い Store。
    public init(_ keyPath: KeyPath<State, Value> & Sendable, store id: StoreID? = nil) {
      self.select = { $0[keyPath: keyPath] }
      self.storeID = id
    }

    /// セレクタ（`createSelector` などで作ったもの）で読みます。
    ///
    /// - Parameters:
    ///   - selector: 値を取り出すセレクタ。
    ///   - id: 読む Store の識別子（`.store(_:id:)` で付けたもの）。`nil` なら、State の型が一致する最も近い Store。
    public init(_ selector: Redux.Selector<State, Value>, store id: StoreID? = nil)
    where Value: Sendable {
      self.select = { selector($0) }
      self.storeID = id
    }

    /// State から値を取り出す関数で読みます。
    ///
    /// - Parameters:
    ///   - id: 読む Store の識別子（`.store(_:id:)` で付けたもの）。`nil` なら、State の型が一致する最も近い Store。
    ///   - select: 値を取り出す関数。
    public init(store id: StoreID? = nil, _ select: @escaping @MainActor (State) -> Value) {
      self.select = select
      self.storeID = id
    }

    /// 読んだ値。
    @MainActor
    public var wrappedValue: Value {
      guard let value = selection.value else {
        if let storeID {
          preconditionFailure(
            "No Store<\(State.self), _> with id \"\(storeID)\" in the environment. Add .store(store, id: \"\(storeID)\") to an ancestor view."
          )
        }
        preconditionFailure(
          "No Store<\(State.self), _> in the environment. Add .store(store) to an ancestor view.")
      }
      return value
    }

    public nonisolated func update() {
      // self ではなく、メインアクターに隔離された値だけを渡す（self は Sendable でないため）。
      let source = storeID.map { namedStores.source(State.self, id: $0) } ?? source
      let (selection, select) = (selection, select)
      MainActor.assumeIsolated {
        guard let source else { return }
        selection.connect(to: source, select: select)
      }
    }
  }

  /// Environment の Store に Action を送る関数を取り出すプロパティラッパー（React Redux の `useDispatch` 相当）。
  ///
  /// `.store(_:)` を入れ子にした場合は、Action の型が一致する Store のうち、最も近い（内側の）ものに送ります。
  /// 送る先を明示したいときは、`.store(_:id:)` で付けた識別子を `store:` で渡します。
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
    @Environment(ActionSink<Action>.self) private var unnamedSink: ActionSink<Action>?
    @Environment(\.namedStores) private var namedStores
    private let storeID: StoreID?

    /// - Parameter id: 送る先の Store の識別子（`.store(_:id:)` で付けたもの）。
    ///   `nil` なら、Action の型が一致する最も近い Store。
    public init(store id: StoreID? = nil) {
      self.storeID = id
    }

    /// Store に Action を送る関数。
    @MainActor
    public var wrappedValue: (Action) -> Void {
      let sink = storeID.map { namedStores.sink(Action.self, id: $0) } ?? unnamedSink
      guard let sink else {
        if let storeID {
          preconditionFailure(
            "No Store<_, \(Action.self)> with id \"\(storeID)\" in the environment. Add .store(store, id: \"\(storeID)\") to an ancestor view."
          )
        }
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
