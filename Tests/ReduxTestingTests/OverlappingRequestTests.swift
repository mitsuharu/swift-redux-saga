import InternalPrimitives
import Redux
import ReduxTesting
import Saga
import Testing

private struct State: Sendable, Equatable {
  var query = ""
  var results = ""
}

private enum Action: Sendable, Equatable {
  case search(String)
  case results(String)
}

private let reducer = Reducer<State, Action> { state, action in
  switch action {
  case .search(let query): state.query = query
  case .results(let results): state.results = results
  }
}

private let search = ActionPattern<Action, String>.case {
  if case .search(let query) = $0 { query } else { nil }
}

/// 応答をテストから手動で返すスタブ。
private final class ManualAPI: Sendable {
  private let pending = Locked<[String: CheckedContinuation<String, Never>]>([:])

  func search(_ query: String) async -> String {
    await withCheckedContinuation { continuation in
      pending.withLock { $0[query] = continuation }
    }
  }

  var waitingQueries: Set<String> {
    Set(pending.withLock { $0.keys })
  }

  func respond(to query: String, with result: String) {
    pending.withLock { $0.removeValue(forKey: query) }?.resume(returning: result)
  }
}

@MainActor
@Suite struct TestStoreOverlappingRequestTests {
  @Test func onlyTheLatestSearchResultIsApplied() async throws {
    let api = ManualAPI()
    let store = TestStore(
      initialState: State(), reducer: reducer,
      saga: Saga { ctx in
        ctx.takeLatest(search) { ctx, query in
          await ctx.put(.results(try await ctx.call(api.search, query)))
        }
      })
    await store.settle()
    try store.dispatch(.search("a")) { $0.query = "a" }
    while !api.waitingQueries.contains("a") { await Task.yield() }
    try store.dispatch(.search("ab")) { $0.query = "ab" }
    while !api.waitingQueries.contains("ab") { await Task.yield() }
    api.respond(to: "ab", with: "ab results")
    try await store.receive(.results("ab results"), timeout: .seconds(5)) {
      $0.results = "ab results"
    }
    // 古い通信の結果は、止めた Saga からは届かない。
    api.respond(to: "a", with: "a results")
    try await store.finish()
  }
}
