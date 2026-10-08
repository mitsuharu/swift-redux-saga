import Observation
import Redux
import Testing

private enum Action: Sendable, Equatable {
  case increment
  case set(Int)
}

private let reducer = Reducer<Int, Action> { state, action in
  switch action {
  case .increment: state += 1
  case .set(let value): state = value
  }
}

@MainActor
@Suite struct StoreTests {
  @Test func initialStateIsAvailableBeforeAnyDispatch() {
    let store = Store(initialState: 10, reducer: reducer)
    #expect(store.state == 10)
  }

  @Test func dispatchUpdatesTheStateSynchronously() {
    let store = Store(initialState: 0, reducer: reducer)
    store.dispatch(.increment)
    store.dispatch(.increment)
    #expect(store.state == 2)
  }

  @Test func readingTheStateRegistersAnObservationThatFiresOnDispatch() {
    let store = Store(initialState: 0, reducer: reducer)
    let changeCount = Box(0)
    track {
      _ = store.state
    } onChange: {
      changeCount.value += 1
    }
    store.dispatch(.increment)
    #expect(changeCount.value == 1)
  }

  @Test func observationIsNotRegisteredWhenTheStateIsNotRead() {
    let store = Store(initialState: 0, reducer: reducer)
    let changeCount = Box(0)
    track {
    } onChange: {
      changeCount.value += 1
    }
    store.dispatch(.increment)
    #expect(changeCount.value == 0)
  }

  @Test func dispatchDuringANotificationIsAppliedAfterTheCurrentAction() {
    let store = Store(initialState: 0, reducer: reducer)
    let stateSeenByTheNotification = Box<Int?>(nil)
    track {
      _ = store.state
    } onChange: {
      // onChange は State の更新前（willSet）に呼ばれる。
      stateSeenByTheNotification.value = store.state
      store.dispatch(.set(100))
    }
    store.dispatch(.increment)
    #expect(stateSeenByTheNotification.value == 0)
    #expect(store.state == 100)
  }
}
