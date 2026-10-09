import Redux
import ReduxTesting
import Saga
import Testing

private enum Action: Sendable, Equatable {
  case ping
  case pong
}

@MainActor
private func eventuallyReleased(_ isReleased: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !isReleased() {
    if ContinuousClock.now > deadline { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

@MainActor
@Suite struct TestStoreMemoryTests {
  @Test func testStoreAndItsStoreAreReleasedAfterFinish() async throws {
    weak var weakTestStore: TestStore<Int, Action>?
    weak var weakStore: Store<Int, Action>?
    do {
      let testStore = TestStore<Int, Action>(
        initialState: 0,
        reducer: Reducer { _, _ in },
        saga: Saga { ctx in
          ctx.takeEvery(.action(.ping)) { ctx, _ in await ctx.put(.pong) }
        })
      weakTestStore = testStore
      weakStore = testStore.store
      try await testStore.send(.ping)
      try testStore.receive(.pong)
      try await testStore.finish()
    }
    #expect(await eventuallyReleased { weakTestStore == nil })
    #expect(await eventuallyReleased { weakStore == nil })
  }
}
