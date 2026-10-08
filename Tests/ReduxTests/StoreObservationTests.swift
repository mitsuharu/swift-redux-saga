import Redux
import Testing

private struct AppState: Sendable, Equatable {
  var count = 0
  var name = ""
}

private enum Action: Sendable {
  case increment
  case rename(String)
}

private let reducer = Reducer<AppState, Action> { state, action in
  switch action {
  case .increment: state.count += 1
  case .rename(let name): state.name = name
  }
}

@MainActor
@Suite struct StoreObservationTests {
  @Test func valuesStartsWithTheCurrentValueAndFollowsChanges() async {
    let store = Store(initialState: AppState(count: 5), reducer: reducer)
    var iterator = store.values { $0.count }.makeAsyncIterator()
    #expect(await iterator.next() == 5)
    store.dispatch(.increment)
    #expect(await iterator.next() == 6)
  }

  @Test func valuesIgnoresChangesToPropertiesThatWereNotRead() async {
    let store = Store(initialState: AppState(), reducer: reducer)
    var iterator = store.values { $0.count }.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    store.dispatch(.rename("a"))
    store.dispatch(.increment)
    #expect(await iterator.next() == 1)
  }

  @Test func valuesDeliversOnlyTheLatestValueWhenTheConsumerIsBehind() async {
    let store = Store(initialState: AppState(), reducer: reducer)
    var iterator = store.values { $0.count }.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    store.dispatch(.increment)
    store.dispatch(.increment)
    store.dispatch(.increment)
    #expect(await iterator.next() == 3)
  }

  @Test func observeCallsTheHandlerWithTheCurrentValueImmediately() {
    let store = Store(initialState: AppState(count: 7), reducer: reducer)
    let received = Box<[Int]>([])
    let token = store.observe {
      $0.count
    } onChange: {
      received.value.append($0)
    }
    #expect(received.value == [7])
    token.cancel()
  }

  @Test func observeCallsTheHandlerAfterAChange() async {
    let store = Store(initialState: AppState(), reducer: reducer)
    let (changes, continuation) = AsyncStream.makeStream(of: Int.self)
    let token = store.observe {
      $0.count
    } onChange: {
      continuation.yield($0)
    }
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == 0)
    store.dispatch(.increment)
    #expect(await iterator.next() == 1)
    token.cancel()
  }

  @Test func cancelledObservationNoLongerCallsTheHandler() async {
    let store = Store(initialState: AppState(), reducer: reducer)
    let received = Box<[Int]>([])
    let token = store.observe {
      $0.count
    } onChange: {
      received.value.append($0)
    }
    token.cancel()

    // 後から登録した購読が通知を受け取った時点で、先に登録した購読の通知も処理済みになっている。
    var sentinel = store.values { $0.count }.makeAsyncIterator()
    #expect(await sentinel.next() == 0)
    store.dispatch(.increment)
    #expect(await sentinel.next() == 1)
    #expect(received.value == [0])
  }

  @Test func releasingTheTokenStopsTheObservation() async {
    let store = Store(initialState: AppState(), reducer: reducer)
    let received = Box<[Int]>([])
    var token: ObservationToken? = store.observe {
      $0.count
    } onChange: {
      received.value.append($0)
    }
    #expect(token != nil)
    token = nil

    var sentinel = store.values { $0.count }.makeAsyncIterator()
    #expect(await sentinel.next() == 0)
    store.dispatch(.increment)
    #expect(await sentinel.next() == 1)
    #expect(received.value == [0])
  }

  @Test func observationDoesNotKeepTheStoreAlive() {
    var store: Store<AppState, Action>? = Store(initialState: AppState(), reducer: reducer)
    weak let weakStore = store
    let token = store?.observe {
      $0.count
    } onChange: { _ in
    }
    store = nil
    #expect(weakStore == nil)
    token?.cancel()
  }
}
