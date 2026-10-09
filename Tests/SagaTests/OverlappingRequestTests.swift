import InternalPrimitives
import Saga
import SagaTesting
import Testing

private enum Action: Sendable, Equatable {
  case search(String)
  case results(String)
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

@Suite struct OverlappingRequestTests {
  @Test func dispatchDoesNotWaitAndReceiveWaitsForTheNextAction() async throws {
    let api = ManualAPI()
    let tester = SagaTester<Int, Action>(
      initialState: 0, reduce: { _, _ in },
      saga: Saga { ctx in
        ctx.takeLatest(search) { ctx, query in
          await ctx.put(.results(try await ctx.call(api.search, query)))
        }
      })
    // 1 つ目の通信が終わる前に、検索語を変える。
    tester.dispatch(.search("a"))
    while !api.waitingQueries.contains("a") { await Task.yield() }
    tester.dispatch(.search("ab"))
    while !api.waitingQueries.contains("ab") { await Task.yield() }
    // 結果が逆の順に届く。
    api.respond(to: "ab", with: "ab results")
    try await tester.receive(.results("ab results"), timeout: .seconds(5))
    api.respond(to: "a", with: "a results")
    await tester.settle()
    #expect(tester.unreceivedActions.isEmpty)
    try await tester.finish()
  }

  @Test func receiveFailsWhenNoActionArrivesInTime() async throws {
    let tester = SagaTester<Int, Action>(
      initialState: 0, reduce: { _, _ in }, saga: Saga { ctx in _ = try await ctx.take(search) })
    await #expect(throws: SagaTesterFailure.self) {
      try await tester.receive(.results("x"), timeout: .milliseconds(10))
    }
    try await tester.finish()
  }
}
