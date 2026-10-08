import Redux
import ReduxSaga
import Saga
import SagaTesting
import Testing

private struct SearchState: Sendable, Equatable {
  @BindableState var query = ""
  @BindableState var isStrict = false
  var results: [String] = []
}

private enum SearchAction: Sendable, Equatable, BindableAction {
  case binding(BindingAction<SearchState>)
  case searched([String])

  var binding: BindingAction<SearchState>? {
    if case .binding(let action) = self { action } else { nil }
  }
}

private let reducer = Reducer<SearchState, SearchAction> {
  Reducer.binding
  Reducer { state, action in
    if case .searched(let results) = action { state.results = results }
  }
}

@Suite struct BindingPatternTests {
  @Test func bindingPatternMatchesChangesOfThatPropertyOnly() async throws {
    let tester = SagaTester(
      initialState: SearchState(),
      reduce: reducer.reduce,
      saga: Saga { ctx in
        ctx.debounce(.milliseconds(300), .binding(\.$query)) { ctx, query in
          await ctx.put(.searched([query]))
        }
      }
    )
    await tester.send(.binding(.set(\.$isStrict, true)))
    await tester.send(.binding(.set(\.$query, "sw")))
    await tester.send(.binding(.set(\.$query, "swift")))
    await tester.advance(by: .milliseconds(300))
    try tester.receive(.searched(["swift"]))
    #expect(tester.state.query == "swift")
    #expect(tester.state.isStrict)
    try await tester.finish()
  }
}
