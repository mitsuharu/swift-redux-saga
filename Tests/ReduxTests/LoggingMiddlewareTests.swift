import Redux
import Testing

private enum Action: Sendable, Equatable {
  case increment
  case secret
}

private let reducer = Reducer<Int, Action> { state, action in
  if action == .increment { state += 1 }
}

@MainActor
@Suite struct LoggingMiddlewareTests {
  @Test(arguments: [true, false])
  func actionsReachTheReducerWhetherLoggingIsEnabledOrNot(isEnabled: Bool) {
    let store = Store(
      initialState: 0, reducer: reducer,
      middleware: [LoggingMiddleware(isEnabled: isEnabled, logsState: true)])
    store.dispatch(.increment)
    store.dispatch(.increment)
    #expect(store.state == 2)
  }

  @Test func filteredActionsStillReachTheReducer() {
    let store = Store(
      initialState: 0, reducer: reducer,
      middleware: [LoggingMiddleware(isEnabled: true, privacy: .public) { $0 != .secret }])
    store.dispatch(.secret)
    store.dispatch(.increment)
    #expect(store.state == 1)
  }
}
