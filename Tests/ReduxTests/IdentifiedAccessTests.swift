import InternalPrimitives
import Observation
import Redux
import Testing

private struct Item: Sendable, Equatable, Identifiable {
  var id: Int
  var title: String
}

private enum Action: Sendable {
  case rename(id: Int, title: String)
  case remove(id: Int)
}

private let reducer = Reducer<[Item], Action> { items, action in
  switch action {
  case .rename(let id, let title): items[id: id]?.title = title
  case .remove(let id): items[id: id] = nil
  }
}

@Suite struct IdentifiedAccessTests {
  @Test func readingByIDReturnsTheElementOrNil() {
    let items = [Item(id: 1, title: "a"), Item(id: 2, title: "b")]
    #expect(items[id: 2]?.title == "b")
    #expect(items[id: 3] == nil)
  }

  @Test func writingByIDReplacesRemovesOrAppends() {
    var items = [Item(id: 1, title: "a"), Item(id: 2, title: "b")]
    items[id: 1]?.title = "A"
    items[id: 2] = nil
    items[id: 3] = Item(id: 3, title: "c")
    #expect(items == [Item(id: 1, title: "A"), Item(id: 3, title: "c")])
  }

  @MainActor
  @Test func storeReadsAnElementByIDSafelyAfterItIsRemoved() async {
    let store = Store(
      initialState: [Item(id: 1, title: "a"), Item(id: 2, title: "b")], reducer: reducer)
    // View が ID で要素を読んでいる状態で、その要素を削除する（添字のキーパスだと範囲外で停止する）。
    let changed = Locked(false)
    withObservationTracking {
      _ = store[id: 2]
    } onChange: {
      changed.withLock { $0 = true }
    }
    store.dispatch(.remove(id: 2))
    #expect(changed.withLock { $0 })
    #expect(store[id: 2] == nil)
  }
}
