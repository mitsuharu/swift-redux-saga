import Redux
import Testing

private enum Counter: Slice {
  struct State: Sendable, Equatable {
    var count = 0
  }

  enum Action: Sendable {
    case increment
    case add(Int)
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .increment: state.count += 1
    case .add(let value): state.count += value
    }
  }
}

private enum Profile: Slice {
  struct State: Sendable, Equatable {
    var name = "guest"
  }

  enum Action: Sendable {
    case rename(String)
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .rename(let name): state.name = name
    }
  }
}

private struct AppState: Sendable, Equatable {
  var counter = Counter.initialState
  var profile = Profile.initialState
}

private enum AppAction: Sendable {
  case counter(Counter.Action)
  case profile(Profile.Action)
}

private let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(Counter.self, state: \.counter) {
    if case .counter(let action) = $0 { action } else { nil }
  }
  Reducer.slice(Profile.self, state: \.profile) {
    if case .profile(let action) = $0 { action } else { nil }
  }
}

@MainActor
@Suite struct SliceTests {
  @Test func sliceReducerAppliesTheSliceReduceFunction() {
    var state = Counter.initialState
    Counter.reducer.reduce(into: &state, action: .add(3))
    #expect(state.count == 3)
  }

  @Test func slicesCanBeCombinedIntoAnAppReducer() {
    let store = Store(initialState: AppState(), reducer: appReducer)
    store.dispatch(.counter(.increment))
    store.dispatch(.profile(.rename("redux")))
    #expect(store.state == AppState(counter: .init(count: 1), profile: .init(name: "redux")))
  }
}
