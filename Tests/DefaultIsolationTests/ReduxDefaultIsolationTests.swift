import Redux
import Testing

// このターゲットは default MainActor isolation が有効なため、宣言は暗黙に @MainActor になる。
// Action と State は Saga（メインアクター外）からも使うので、推奨どおり nonisolated で宣言する。

nonisolated enum CounterAction: Sendable, Equatable {
  case increment
  case add(Int)
}

nonisolated struct CounterState: Sendable, Equatable {
  var count = 0
}

nonisolated enum AppAction: Sendable, Equatable {
  case counter(CounterAction)
}

nonisolated struct AppState: Sendable, Equatable {
  var counter = CounterState()
}

// グローバルな reducer も暗黙に @MainActor になるため、メインアクター外（Saga やテスト）から使うなら nonisolated にする。
nonisolated let counterReducer = Reducer<CounterState, CounterAction> { state, action in
  switch action {
  case .increment: state.count += 1
  case .add(let value): state.count += value
  }
}

nonisolated let appReducer = Reducer<AppState, AppAction> {
  Reducer.scope(
    state: \.counter,
    action: { if case .counter(let action) = $0 { action } else { nil } },
    reducer: counterReducer
  )
}

// default isolation により、このミドルウェアは暗黙に @MainActor になる。
final class RecordingMiddleware: Middleware {
  private(set) var actions: [AppAction] = []

  func handle(
    _ action: AppAction, store: MiddlewareAPI<AppState, AppAction>, next: (AppAction) -> Void
  ) {
    actions.append(action)
    next(action)
  }
}

@Suite struct ReduxDefaultIsolationTests {
  @Test func storeWorksWithImplicitlyMainActorDeclarations() {
    let middleware = RecordingMiddleware()
    let store = Store(initialState: AppState(), reducer: appReducer, middleware: [middleware])
    store.dispatch(.counter(.increment))
    store.dispatch(.counter(.add(2)))
    #expect(store.counter.count == 3)
    #expect(middleware.actions == [.counter(.increment), .counter(.add(2))])
  }

  @Test func reducerCanBeCalledOffTheMainActor() async {
    let state = await Task.detached {
      var state = AppState()
      appReducer.reduce(into: &state, action: .counter(.add(5)))
      return state
    }.value
    #expect(state.counter.count == 5)
  }

  @Test func valuesCanBeConsumedFromImplicitlyMainActorCode() async {
    let store = Store(initialState: AppState(), reducer: appReducer)
    var iterator = store.values { $0.counter.count }.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    store.dispatch(.counter(.increment))
    #expect(await iterator.next() == 1)
  }
}

// default isolation のモジュールでは、Slice は nonisolated で宣言する。
nonisolated enum Toggle: Slice {
  struct State: Sendable, Equatable {
    var isOn = false
  }

  enum Action: Sendable {
    case toggle
  }

  static let initialState = State()

  static func reduce(into state: inout State, action: Action) {
    state.isOn.toggle()
  }
}

@Suite struct SliceDefaultIsolationTests {
  @Test func nonisolatedSliceWorksInADefaultMainActorModule() {
    let store = Store(initialState: Toggle.initialState, reducer: Toggle.reducer)
    store.dispatch(.toggle)
    #expect(store.isOn)
  }
}
