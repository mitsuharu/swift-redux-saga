import Redux
import Testing

private enum CounterAction: Sendable {
  case increment
  case add(Int)
}

private enum AppAction: Sendable {
  case counter(CounterAction)
  case rename(String)
}

private struct AppState: Sendable, Equatable {
  var count = 0
  var name = ""
}

private let counter = Reducer<Int, CounterAction> { state, action in
  switch action {
  case .increment: state += 1
  case .add(let value): state += value
  }
}

private let counterInApp = Reducer<AppState, AppAction>.scope(
  state: \.count,
  action: { if case .counter(let action) = $0 { action } else { nil } },
  reducer: counter
)

private let renameInApp = Reducer<AppState, AppAction> { state, action in
  if case .rename(let name) = action { state.name = name }
}

@Suite struct ReducerTests {
  @Test func reduceAppliesTheActionToTheState() {
    var state = 0
    counter.reduce(into: &state, action: .add(3))
    #expect(state == 3)
  }

  @Test func emptyLeavesTheStateUnchanged() {
    var state = 5
    Reducer<Int, CounterAction>.empty.reduce(into: &state, action: .increment)
    #expect(state == 5)
  }

  @Test func combineAppliesReducersInArgumentOrder() {
    let double = Reducer<Int, CounterAction> { state, _ in state *= 2 }
    var state = 1
    Reducer.combine(counter, double).reduce(into: &state, action: .increment)
    #expect(state == 4)
  }

  @Test func scopeForwardsOnlyMatchingActionsToTheChild() {
    var state = AppState()
    counterInApp.reduce(into: &state, action: .counter(.add(2)))
    counterInApp.reduce(into: &state, action: .rename("x"))
    #expect(state == AppState(count: 2, name: ""))
  }

  @Test func builderAppliesReducersFromTopToBottom() {
    let app = Reducer<AppState, AppAction> {
      counterInApp
      renameInApp
    }
    var state = AppState()
    app.reduce(into: &state, action: .counter(.increment))
    app.reduce(into: &state, action: .rename("redux"))
    #expect(state == AppState(count: 1, name: "redux"))
  }

  @Test(arguments: [true, false])
  func builderIncludesAConditionalReducerOnlyWhenTheConditionHolds(includeRename: Bool) {
    let app = Reducer<AppState, AppAction> {
      counterInApp
      if includeRename {
        renameInApp
      }
    }
    var state = AppState()
    app.reduce(into: &state, action: .rename("redux"))
    #expect(state.name == (includeRename ? "redux" : ""))
  }

  @Test(arguments: [true, false])
  func builderPicksOneBranchOfIfElse(useCounter: Bool) {
    let app = Reducer<AppState, AppAction> {
      if useCounter {
        counterInApp
      } else {
        renameInApp
      }
    }
    var state = AppState()
    app.reduce(into: &state, action: .counter(.increment))
    #expect(state.count == (useCounter ? 1 : 0))
  }

  @Test func builderAppliesEveryReducerProducedByALoop() {
    let app = Reducer<AppState, AppAction> {
      for _ in 0..<3 {
        counterInApp
      }
    }
    var state = AppState()
    app.reduce(into: &state, action: .counter(.increment))
    #expect(state.count == 3)
  }
}
