import Redux
import Testing

private struct NotEquatable: Sendable {
  var value = 0
}

private struct AppState: Sendable, Equatable {
  struct Profile: Sendable, Equatable {
    var name = ""
    var age = 0
  }

  var count = 0
  var profile = Profile()
  var items: [Int] = []

  static func == (lhs: AppState, rhs: AppState) -> Bool {
    lhs.count == rhs.count && lhs.profile == rhs.profile && lhs.items == rhs.items
  }
}

private enum Action: Sendable {
  case increment
  case rename(String)
  case append(Int)
  case noop
}

private let reducer = Reducer<AppState, Action> { state, action in
  switch action {
  case .increment: state.count += 1
  case .rename(let name): state.profile.name = name
  case .append(let item): state.items.append(item)
  case .noop: break
  }
}

private struct LooseState: Sendable {
  var count = 0
  var other = NotEquatable()
}

private let looseReducer = Reducer<LooseState, Action> { state, action in
  switch action {
  case .increment: state.count += 1
  case .rename: state.other.value += 1
  case .append, .noop: break
  }
}

@MainActor
@Suite struct KeyPathObservationTests {
  /// `read` の中で読んだ値について、各 Action の dispatch で通知されたかどうかを返す。
  private func notifications<State>(
    _ store: Store<State, Action>,
    reading read: @escaping @MainActor () -> Void,
    actions: [Action]
  ) -> [Bool] {
    actions.map { action in
      let notified = Box(false)
      track(read) { notified.value = true }
      store.dispatch(action)
      return notified.value
    }
  }

  @Test func readingAPropertyNotifiesOnlyWhenThatPropertyChanges() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let result = notifications(
      store, reading: { _ = store.count }, actions: [.rename("a"), .increment, .append(1)])
    #expect(result == [false, true, false])
  }

  @Test func readingANestedValueIsTrackedByTheTopLevelPropertyReadThroughTheStore() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let result = notifications(
      store, reading: { _ = store.profile.name }, actions: [.increment, .rename("a"), .rename("a")])
    #expect(result == [false, true, false])
  }

  @Test func readingTheWholeStateNotifiesOnlyWhenTheStateChanges() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let result = notifications(
      store, reading: { _ = store.state }, actions: [.noop, .increment, .rename("a")])
    #expect(result == [false, true, true])
  }

  @Test func readingANonEquatablePropertyNotifiesOnEveryDispatch() {
    let store = Store(initialState: LooseState(), reducer: looseReducer)
    let result = notifications(
      store, reading: { _ = store.other }, actions: [.noop, .increment])
    #expect(result == [true, true])
  }

  @Test func readingAnEquatablePropertyOfANonEquatableStateIsStillTrackedPerProperty() {
    let store = Store(initialState: LooseState(), reducer: looseReducer)
    let result = notifications(
      store, reading: { _ = store.count }, actions: [.noop, .rename("a"), .increment])
    #expect(result == [false, false, true])
  }

  @Test func theNotificationSeesTheStateBeforeTheChange() {
    let store = Store(initialState: AppState(), reducer: reducer)
    let seen = Box<[Int]>([])
    track {
      _ = store.count
      _ = store.profile
    } onChange: {
      seen.value.append(store.count)
    }
    store.dispatch(.increment)
    #expect(seen.value == [0])
    #expect(store.count == 1)
  }

  @Test func dynamicMemberReturnsTheCurrentValue() {
    let store = Store(initialState: AppState(), reducer: reducer)
    store.dispatch(.append(3))
    store.dispatch(.rename("redux"))
    #expect(store.items == [3])
    #expect(store.profile.name == "redux")
  }
}
