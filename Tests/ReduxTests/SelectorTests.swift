import InternalPrimitives
import Redux
import Testing

private struct Todo: Sendable, Equatable {
  var title: String
  var done: Bool
}

private enum Filter: Sendable, Equatable {
  case all
  case active
}

private struct AppState: Sendable, Equatable {
  var todos: [Todo] = []
  var filter = Filter.all
  var unrelated = 0
}

private let sample = AppState(
  todos: [Todo(title: "a", done: true), Todo(title: "b", done: false)],
  filter: .active
)

/// result が呼ばれた回数を数えるセレクタを作る。
private func makeVisibleTodos() -> (Selector<AppState, [Todo]>, Locked<Int>) {
  let calls = Locked(0)
  let selector = createSelector(\AppState.todos, \.filter) { todos, filter in
    calls.withLock { $0 += 1 }
    return filter == .all ? todos : todos.filter { !$0.done }
  }
  return (selector, calls)
}

@Suite struct SelectorTests {
  @Test func selectorComputesTheResultFromTheInputs() {
    let (visibleTodos, _) = makeVisibleTodos()
    #expect(visibleTodos(sample) == [Todo(title: "b", done: false)])
  }

  @Test func selectorReusesTheLastResultWhenTheInputsAreUnchanged() {
    let (visibleTodos, calls) = makeVisibleTodos()
    var state = sample
    _ = visibleTodos(state)
    state.unrelated += 1
    _ = visibleTodos(state)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test func selectorRecomputesWhenAnyInputChanges() {
    let (visibleTodos, calls) = makeVisibleTodos()
    var state = sample
    _ = visibleTodos(state)
    state.filter = .all
    #expect(visibleTodos(state).count == 2)
    state.todos.append(Todo(title: "c", done: false))
    #expect(visibleTodos(state).count == 3)
    #expect(calls.withLock { $0 } == 3)
  }

  @Test func selectorWithASingleInputWorks() {
    let count: Selector<AppState, Int> = createSelector({ $0.todos }, result: { $0.count })
    #expect(count(sample) == 2)
  }

  @Test func plainSelectorDoesNotMemoize() {
    let calls = Locked(0)
    let selector = Selector<AppState, Int> { state in
      calls.withLock { $0 += 1 }
      return state.unrelated
    }
    _ = selector(sample)
    _ = selector(sample)
    #expect(calls.withLock { $0 } == 2)
  }

  @Test func selectorIsSafeToCallConcurrently() async {
    let (visibleTodos, _) = makeVisibleTodos()
    await withDiscardingTaskGroup { group in
      for index in 0..<200 {
        group.addTask {
          var state = sample
          state.filter = index.isMultiple(of: 2) ? .all : .active
          let expected = index.isMultiple(of: 2) ? 2 : 1
          #expect(visibleTodos(state).count == expected)
        }
      }
    }
  }
}
