#if canImport(SwiftUI)
  import Observation
  import Redux
  import Testing

  @testable import ReduxSwiftUI

  private struct ListState: Sendable, Equatable {
    var items: [Int] = []
    var other = 0
  }

  private enum ListAction: Sendable {
    case add(Int)
    case touchOther
  }

  private let reducer = Reducer<ListState, ListAction> { state, action in
    switch action {
    case .add(let value): state.items.append(value)
    case .touchOther: state.other += 1
    }
  }

  private let evenCount = createSelector(\ListState.items) { items in
    items.filter { $0.isMultiple(of: 2) }.count
  }

  @MainActor
  @Suite struct StoreHooksTests {
    @Test func aSelectionReadsTheSelectedValueRightAway() {
      let store = Store(initialState: ListState(items: [2, 3]), reducer: reducer)
      let selection = Selection<Int>()
      selection.connect(to: StoreSource(store)) { evenCount($0) }
      #expect(selection.value == 1)
    }

    @Test func aSelectionChangesOnlyWhenTheSelectedValueChanges() async {
      let store = Store(initialState: ListState(), reducer: reducer)
      let selection = Selection<Int>()
      selection.connect(to: StoreSource(store)) { evenCount($0) }
      // View と同じく selection.value を購読し、変化したときの値を順に受け取る。
      let (values, continuation) = AsyncStream.makeStream(of: Int?.self)
      let token = ObservationToken.observe {
        selection.value
      } onChange: {
        continuation.yield($0)
      }
      var iterator = values.makeAsyncIterator()
      #expect(await iterator.next() == 0)
      // 関係のない変更と、結果が変わらない変更の後に、結果が変わる変更をする。
      store.dispatch(.touchOther)
      store.dispatch(.add(1))
      store.dispatch(.add(2))
      // 途中の変更で値が書き換わっていれば、ここで 0 が届く。
      #expect(await iterator.next() == 1)
      store.dispatch(.add(3))
      store.dispatch(.add(4))
      #expect(await iterator.next() == 2)
      token.cancel()
    }

    @Test func anActionSinkDispatchesToTheStore() {
      let store = Store(initialState: ListState(), reducer: reducer)
      ActionSink(store).dispatch(.add(4))
      #expect(store.items == [4])
    }

    @Test func sourcesDoNotKeepTheStoreAlive() {
      weak var weakStore: Store<ListState, ListAction>?
      var source: StoreSource<ListState>?
      var sink: ActionSink<ListAction>?
      do {
        let store = Store(initialState: ListState(), reducer: reducer)
        weakStore = store
        source = StoreSource(store)
        sink = ActionSink(store)
      }
      #expect(weakStore == nil)
      _ = (source, sink)
    }
  }
#endif
