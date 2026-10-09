import InternalPrimitives
import Observation
import Redux
import Testing

/// ID を読んだ回数を数える要素。
private struct Item: Sendable, Equatable, Identifiable {
  static let reads = Locked(0)
  let rawID: Int

  var id: Int {
    Self.reads.withLock { $0 += 1 }
    return rawID
  }
}

private struct ListState: Sendable, Equatable {
  var items: [Item] = []
  var other = 0
}

private enum ListAction: Sendable {
  case keep(Int)
  case touchOther
}

private let reducer = Reducer<ListState, ListAction> { state, action in
  switch action {
  case .keep(let count): state.items = Array(state.items.prefix(count))
  case .touchOther: state.other += 1
  }
}

@MainActor
@Suite(.serialized) struct TrackedKeyPathPruningTests {
  @Test func keyPathsThatChangedAreNoLongerComparedOnLaterDispatches() {
    let store = Store(
      initialState: ListState(items: (0..<1000).map(Item.init(rawID:))), reducer: reducer)
    // 一覧の画面が、ID ごとのキーパスで 1,000 件を読んだ。
    for id in 0..<1000 {
      withObservationTracking {
        _ = store[dynamicMember: \.items[id: id]]
      } onChange: {
      }
    }
    // 1 件を残して削除する。削除した要素のキーパスは値が変わったので通知され、比較の対象から外れる。
    store.dispatch(.keep(1))
    Item.reads.withLock { $0 = 0 }
    // 一覧と関係のない Action では、残っている 1 件のキーパスだけを比べる。
    store.dispatch(.touchOther)
    #expect(Item.reads.withLock { $0 } <= 4)
  }

  @Test func aKeyPathThatIsReadAgainAfterChangingIsStillTracked() {
    let store = Store(
      initialState: ListState(items: (0..<3).map(Item.init(rawID:))), reducer: reducer)
    withObservationTracking {
      _ = store[dynamicMember: \.items[id: 2]]
    } onChange: {
    }
    store.dispatch(.keep(2))  // id 2 が消える（通知され、比較の対象から外れる）
    // 通知を受けた側が読み直すと、再び追跡される。
    let changed = Locked(false)
    withObservationTracking {
      _ = store[dynamicMember: \.items[id: 1]]
    } onChange: {
      changed.withLock { $0 = true }
    }
    store.dispatch(.keep(1))
    #expect(changed.withLock { $0 })
  }
}
