#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import Redux
  import ReduxSwiftUI
  import SwiftUI
  import Testing

  private struct ParentState: Sendable, Equatable { var count = 0 }
  private struct ChildState: Sendable, Equatable { var count = 0 }
  private enum SharedAction: Sendable { case add(Int) }
  private enum OtherAction: Sendable { case add(Int) }

  private let parentReducer = Reducer<ParentState, SharedAction> { state, action in
    switch action {
    case .add(let n): state.count += n
    }
  }
  private let childReducer = Reducer<ChildState, SharedAction> { state, action in
    switch action {
    case .add(let n): state.count += n
    }
  }
  private let parentOtherReducer = Reducer<ParentState, OtherAction> { state, action in
    switch action {
    case .add(let n): state.count += n
    }
  }

  /// View が読んだ値と、View から取り出した dispatch を記録する。
  @MainActor
  private final class Probe<Action> {
    private(set) var read: Int?
    private(set) var environmentRead: Int?
    private(set) var dispatch: ((Action) -> Void)?

    func record(read: Int, environmentRead: Int? = nil, dispatch: @escaping (Action) -> Void) {
      self.read = read
      self.environmentRead = environmentRead
      self.dispatch = dispatch
    }
  }

  /// `@SelectState` で `State` の count を読み、`@DispatchAction` で `Action` を取り出す。
  private struct HookView<State: Sendable, Action: Sendable>: View {
    let probe: Probe<Action>
    @SelectState<State, Int> private var count: Int
    @DispatchAction<Action> private var dispatch: (Action) -> Void

    init(_ keyPath: KeyPath<State, Int> & Sendable, probe: Probe<Action>) {
      self.probe = probe
      _count = SelectState(keyPath)
    }

    var body: some View {
      let _ = probe.record(read: count, dispatch: dispatch)
      Text("\(count)")
    }
  }

  @MainActor
  @Suite struct StoreHooksStoreResolutionTests {
    @Test
    func
      withTheSameActionTypeSelectStateReadsTheStoreOfItsStateAndDispatchActionSendsToTheInnerStore()
      async
    {
      // 外側: Store<ParentState, SharedAction>、内側: Store<ChildState, SharedAction>
      let outer = Store(initialState: ParentState(count: 1), reducer: parentReducer)
      let inner = Store(initialState: ChildState(count: 100), reducer: childReducer)
      let probe = Probe<SharedAction>()
      let host = Host(
        HookView(\ParentState.count, probe: probe)
          .store(inner)
          .store(outer))
      // State の型が ParentState の入口は外側にしかない。
      #expect(await host.waitUntil { probe.read == 1 })
      // Action の型が SharedAction の入口は、内側が外側を上書きしている。
      probe.dispatch?(.add(5))
      #expect(inner.state.count == 105)
      #expect(outer.state.count == 1)
    }

    @Test
    func
      withTheSameStateTypeSelectStateReadsTheInnerStoreAndDispatchActionSendsToTheStoreOfItsAction()
      async
    {
      // 外側: Store<ParentState, OtherAction>、内側: Store<ParentState, SharedAction>
      let outer = Store(initialState: ParentState(count: 1), reducer: parentOtherReducer)
      let inner = Store(initialState: ParentState(count: 100), reducer: parentReducer)
      let probe = Probe<OtherAction>()
      let host = Host(
        HookView(\ParentState.count, probe: probe)
          .store(inner)
          .store(outer))
      // State の型が ParentState の入口は、内側が外側を上書きしている。
      #expect(await host.waitUntil { probe.read == 100 })
      // Action の型が OtherAction の入口は外側にしかない。
      probe.dispatch?(.add(5))
      #expect(outer.state.count == 6)
      #expect(inner.state.count == 100)
    }

    @Test func withTheSameStoreTypeEveryWayOfReadingUsesTheInnerStore() async {
      // 外側も内側も Store<ParentState, SharedAction>
      let outer = Store(initialState: ParentState(count: 1), reducer: parentReducer)
      let inner = Store(initialState: ParentState(count: 100), reducer: parentReducer)
      let probe = Probe<SharedAction>()
      let host = Host(
        EnvironmentStoreView(probe: probe)
          .store(inner)
          .store(outer))
      #expect(await host.waitUntil { probe.read == 100 && probe.environmentRead == 100 })
      probe.dispatch?(.add(5))
      #expect(inner.state.count == 105)
      #expect(outer.state.count == 1)
    }
  }

  /// フックと `@Environment(Store<State, Action>.self)` の両方で読む。
  private struct EnvironmentStoreView: View {
    let probe: Probe<SharedAction>
    @Environment(Store<ParentState, SharedAction>.self) private var store
    @SelectState(\ParentState.count) private var count
    @DispatchAction private var dispatch: (SharedAction) -> Void

    var body: some View {
      let _ = probe.record(read: count, environmentRead: store.count, dispatch: dispatch)
      Text("\(count) \(store.count)")
    }
  }
#endif
