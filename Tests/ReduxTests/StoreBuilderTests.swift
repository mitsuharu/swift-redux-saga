import Redux
import Testing

private struct AppState: Sendable, Equatable {
  var count = 0
  var log: [String] = []
}

private enum Action: Sendable {
  case increment
}

@MainActor
private struct Tagger: Middleware {
  let tag: String
  let log: Box<[String]>

  func handle(_ action: Action, store: MiddlewareAPI<AppState, Action>, next: (Action) -> Void) {
    log.value.append(tag)
    next(action)
  }
}

@MainActor
@Suite struct StoreBuilderTests {
  @Test func builderComposesReducersAndMiddlewareInOrder() {
    let log = Box<[String]>([])
    let store = Store<AppState, Action>(initialState: AppState()) {
      Reducer { state, _ in state.count += 1 }
      Reducer { state, _ in state.log.append("count=\(state.count)") }
    } middleware: {
      Tagger(tag: "a", log: log)
      Tagger(tag: "b", log: log)
    }
    store.dispatch(.increment)
    #expect(store.state == AppState(count: 1, log: ["count=1"]))
    #expect(log.value == ["a", "b"])
  }

  @Test(arguments: [true, false])
  func builderIncludesConditionalMiddlewareOnlyWhenTheConditionHolds(isDebug: Bool) {
    let log = Box<[String]>([])
    let store = Store<AppState, Action>(initialState: AppState()) {
      Reducer { state, _ in state.count += 1 }
    } middleware: {
      Tagger(tag: "always", log: log)
      if isDebug {
        Tagger(tag: "debug", log: log)
      }
    }
    store.dispatch(.increment)
    #expect(log.value == (isDebug ? ["always", "debug"] : ["always"]))
  }

  @Test func middlewareCanBeOmitted() {
    let store = Store<AppState, Action>(initialState: AppState()) {
      Reducer { state, _ in state.count += 1 }
    }
    store.dispatch(.increment)
    #expect(store.count == 1)
  }
}
