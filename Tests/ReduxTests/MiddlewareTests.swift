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

/// 呼ばれた順序と、その時点の State を記録するミドルウェア。
@MainActor
private final class Recorder: Middleware {
  let name: String
  let log: Box<[String]>
  private(set) var attachCount = 0

  init(_ name: String, log: Box<[String]>) {
    self.name = name
    self.log = log
  }

  func attach(to store: MiddlewareAPI<Int, Action>) {
    attachCount += 1
  }

  func handle(_ action: Action, store: MiddlewareAPI<Int, Action>, next: (Action) -> Void) {
    log.value.append("\(name) before \(store.state)")
    next(action)
    log.value.append("\(name) after \(store.state)")
  }
}

@MainActor
private struct Blocker: Middleware {
  func handle(_ action: Action, store: MiddlewareAPI<Int, Action>, next: (Action) -> Void) {
    if action != .increment { next(action) }
  }
}

@MainActor
private struct Transformer: Middleware {
  func handle(_ action: Action, store: MiddlewareAPI<Int, Action>, next: (Action) -> Void) {
    next(action == .increment ? .set(42) : action)
  }
}

@MainActor
private struct FollowUp: Middleware {
  func handle(_ action: Action, store: MiddlewareAPI<Int, Action>, next: (Action) -> Void) {
    next(action)
    if action == .increment { store.dispatch(.set(store.state * 10)) }
  }
}

@MainActor
private final class Holder: Middleware {
  var api: MiddlewareAPI<Int, Action>?
  func attach(to store: MiddlewareAPI<Int, Action>) { api = store }
  func handle(_ action: Action, store: MiddlewareAPI<Int, Action>, next: (Action) -> Void) {
    next(action)
  }
}

@MainActor
@Suite struct MiddlewareTests {
  @Test func middlewareRunsInArrayOrderAroundTheReducer() {
    let log = Box<[String]>([])
    let store = Store(
      initialState: 0, reducer: reducer,
      middleware: [Recorder("a", log: log), Recorder("b", log: log)])
    store.dispatch(.increment)
    #expect(log.value == ["a before 0", "b before 0", "b after 1", "a after 1"])
  }

  @Test func attachIsCalledOnceWhenTheStoreIsCreated() {
    let recorder = Recorder("a", log: Box([]))
    let store = Store(initialState: 0, reducer: reducer, middleware: [recorder])
    store.dispatch(.increment)
    store.dispatch(.increment)
    #expect(recorder.attachCount == 1)
  }

  @Test func anActionDoesNotReachTheReducerWhenNextIsNotCalled() {
    let store = Store(initialState: 0, reducer: reducer, middleware: [Blocker()])
    store.dispatch(.increment)
    store.dispatch(.set(5))
    #expect(store.state == 5)
  }

  @Test func middlewareCanReplaceTheActionPassedToNext() {
    let store = Store(initialState: 0, reducer: reducer, middleware: [Transformer()])
    store.dispatch(.increment)
    #expect(store.state == 42)
  }

  @Test func dispatchFromMiddlewareRunsAfterTheCurrentActionThroughTheWholeChain() {
    let log = Box<[String]>([])
    let store = Store(
      initialState: 0, reducer: reducer,
      middleware: [Recorder("a", log: log), FollowUp()])
    store.dispatch(.increment)
    #expect(store.state == 10)
    #expect(log.value == ["a before 0", "a after 1", "a before 1", "a after 10"])
  }

  @Test func middlewareAPIDoesNotKeepTheStoreAlive() {
    let holder = Holder()
    var store: Store<Int, Action>? = Store(initialState: 0, reducer: reducer, middleware: [holder])
    #expect(holder.api?.isStoreAlive == true)
    store = nil
    #expect(store == nil)
    #expect(holder.api?.isStoreAlive == false)
    holder.api?.dispatch(.increment)  // 解放後の dispatch は何もしない
  }
}
