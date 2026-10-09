import InternalPrimitives
import Observation
import Redux
import Testing

private struct CounterState: Sendable, Equatable {
  var count = 0
  var label = ""
}

private enum CounterAction: Sendable, Equatable {
  case increment
  case rename(String)
}

private struct AppState: Sendable, Equatable {
  var counter = CounterState()
  var other = 0
}

private enum AppAction: Sendable, Equatable {
  case counter(CounterAction)
  case touchOther
}

private let reducer = Reducer<AppState, AppAction> { state, action in
  switch action {
  case .counter(.increment): state.counter.count += 1
  case .counter(.rename(let label)): state.counter.label = label
  case .touchOther: state.other += 1
  }
}

/// 読んだ値が変わったら true になる。
@MainActor
private func observeChange(_ read: @escaping @MainActor () -> Void) -> Locked<Bool> {
  let changed = Locked(false)
  withObservationTracking(read) { changed.withLock { $0 = true } }
  return changed
}

@MainActor
@Suite struct StoreScopeTests {
  @Test func aScopedStoreReadsTheChildStateAndSendsActionsToTheParent() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let counter = store.scope(state: \.counter, action: AppAction.counter)
    #expect(counter.count == 0)
    counter.dispatch(.increment)
    #expect(store.counter.count == 1)
    #expect(counter.count == 1)
    store.dispatch(.counter(.rename("a")))
    #expect(counter.label == "a")
  }

  @Test func readingAScopedStoreTracksOnlyThatProperty() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let counter = store.scope(state: \.counter, action: AppAction.counter)
    let countChanged = observeChange { _ = counter.count }
    store.dispatch(.touchOther)
    counter.dispatch(.rename("a"))
    #expect(countChanged.withLock { $0 } == false)
    counter.dispatch(.increment)
    #expect(countChanged.withLock { $0 })
  }

  @Test func aStoreScopedFromAScopedStoreFollowsTheRoot() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let count = store.scope(state: \.counter, action: AppAction.counter)
      .scope(state: \.count, action: { (action: CounterAction) in action })
    let changed = observeChange { _ = count.state }
    store.dispatch(.counter(.increment))
    #expect(count.state == 1)
    #expect(changed.withLock { $0 })
  }

  @Test func aScopedStoreKeepsItsParentAliveAndBothAreReleasedTogether() {
    weak var weakStore: Store<AppState, AppAction>?
    var counter: Store<CounterState, CounterAction>?
    do {
      let store = Store(initialState: AppState(), reducer: reducer)
      weakStore = store
      counter = store.scope(state: \.counter, action: AppAction.counter)
    }
    #expect(weakStore != nil)
    counter?.dispatch(.increment)
    #expect(counter?.count == 1)
    weak let weakCounter = counter
    counter = nil
    #expect(weakCounter == nil)
    #expect(weakStore == nil)
  }

  @Test func releasedScopedStoresAreNoLongerNotified() {
    let store = Store(initialState: AppState(), reducer: reducer)
    weak var weakCounter: Store<CounterState, CounterAction>?
    do {
      let counter = store.scope(state: \.counter, action: AppAction.counter)
      weakCounter = counter
    }
    #expect(weakCounter == nil)
    store.dispatch(.counter(.increment))
    #expect(store.counter.count == 1)
  }
}
