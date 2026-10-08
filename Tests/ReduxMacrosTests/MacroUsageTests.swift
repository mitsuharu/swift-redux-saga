import Redux
import ReduxMacros
import Saga
import SagaTesting
import Testing

@ActionCases
enum UserAction: Sendable, Equatable {
  case fetch(id: Int)
  case search(String)
}

@Slice
enum Counter {
  struct State: Sendable, Equatable {
    var count = 0
  }

  enum Action: Sendable, Equatable {
    case increment
    case add(Int)
  }

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .increment: state.count += 1
    case .add(let value): state.count += value
    }
  }
}

@ActionCases
enum AppAction: Sendable, Equatable {
  case counter(Counter.Action)
  case user(UserAction)
  case rename(first: String, last: String)
  case reset
}

struct AppState: Sendable, Equatable {
  var counter = Counter.initialState
  var name = ""
}

let appReducer = Reducer<AppState, AppAction> {
  Reducer.slice(Counter.self, state: \.counter, action: \.counter)
  Reducer { state, action in
    if let (first, last) = action.rename { state.name = "\(first) \(last)" }
    if action.reset != nil { state = AppState() }
  }
}

@Suite struct MacroUsageTests {
  @Test func casePropertiesReturnTheAssociatedValueOnlyForTheirCase() {
    #expect(AppAction.user(.search("swift")).user == .search("swift"))
    #expect(AppAction.reset.user == nil)
    #expect(AppAction.reset.reset != nil)
    #expect(AppAction.user(.fetch(id: 3)).user?.fetch == 3)
    let rename = AppAction.rename(first: "a", last: "b").rename
    #expect(rename?.first == "a")
    #expect(rename?.last == "b")
  }

  @Test func sliceMacroMakesTheEnumASliceWithAnInitialState() {
    #expect(Counter.initialState == Counter.State())
    var state = Counter.initialState
    Counter.reducer.reduce(into: &state, action: .add(2))
    #expect(state.count == 2)
    #expect(Counter.Action.add(2).add == 2)  // Action にも @ActionCases が付く
  }

  @MainActor
  @Test func keyPathsFromActionCasesWorkWithReducers() {
    let store = Store(initialState: AppState(), reducer: appReducer)
    store.dispatch(.counter(.increment))
    store.dispatch(.rename(first: "Ada", last: "Lovelace"))
    #expect(store.state == AppState(counter: .init(count: 1), name: "Ada Lovelace"))
  }

  @Test func keyPathsFromActionCasesWorkAsSagaPatterns() async throws {
    let tester = SagaTester(
      initialState: AppState(),
      reduce: appReducer.reduce,
      saga: Saga { ctx in
        ctx.takeEvery(.case(\.user?.fetch)) { ctx, id in
          await ctx.put(.rename(first: "user", last: "\(id)"))
        }
      }
    )
    await tester.send(.user(.search("ignored")))
    await tester.send(.user(.fetch(id: 7)))
    try tester.receive(.rename(first: "user", last: "7"))
    #expect(tester.state.name == "user 7")
    try await tester.finish()
  }
}

// @Slice の中の Action には @ActionCases が付き、`var binding` が生成されるので、
// case binding を書くだけで BindableAction に準拠できる。
@Slice
enum Settings {
  struct State: Sendable, Equatable {
    @BindableState var nickname = ""
  }

  enum Action: Sendable, Equatable, BindableAction {
    case binding(BindingAction<State>)
  }

  static func reduce(into state: inout State, action: Action) {
    switch action {
    case .binding(let binding): binding.apply(to: &state)
    }
  }
}

@Suite struct BindableActionMacroTests {
  @Test func actionCasesSatisfiesBindableAction() {
    var state = Settings.initialState
    Settings.reducer.reduce(into: &state, action: .binding(.set(\.$nickname, "ada")))
    #expect(state.nickname == "ada")
    #expect(Settings.Action.binding(.set(\.$nickname, "x")).binding == .set(\.$nickname, "x"))
  }
}
