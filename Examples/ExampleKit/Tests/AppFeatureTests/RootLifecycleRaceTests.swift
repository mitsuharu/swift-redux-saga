import AppFeature
import Domain
import Saga
import Testing

/// State を取得してから Saga に返すまでを止め、select と次の take の間に Action を届ける。
private actor LifecycleHost: SagaHost {
  typealias State = RootFeature.State
  typealias Action = RootFeature.Action

  private var current = RootFeature.initialState
  private weak var runtime: SagaRuntime<State, Action>?
  private var holdsNextRead = false
  private let resumeRead: AsyncStream<Void>
  let didRead: AsyncStream<Void>
  private let readContinuation: AsyncStream<Void>.Continuation
  private let resumeContinuation: AsyncStream<Void>.Continuation
  private(set) var dispatched: [Action] = []

  init() {
    (didRead, readContinuation) = AsyncStream.makeStream()
    (resumeRead, resumeContinuation) = AsyncStream.makeStream()
  }

  func attach(_ runtime: SagaRuntime<State, Action>) { self.runtime = runtime }
  func holdNextRead() { holdsNextRead = true }
  func releaseRead() { resumeContinuation.yield(()) }

  func state() async -> State {
    let snapshot = current
    if holdsNextRead {
      holdsNextRead = false
      readContinuation.yield(())
      for await _ in resumeRead { break }
    }
    return snapshot
  }

  func dispatch(_ action: Action) async {
    RootFeature.reducer.reduce(into: &current, action: action)
    dispatched.append(action)
    runtime?.emit(action)
  }
}

@Suite struct RootLifecycleRaceTests {
  @Test func aReloginWhileReadingStateStillRestartsTheTodoSession() async throws {
    let host = LifecycleHost()
    let runtime = SagaRuntime(host: host)
    await host.attach(runtime)
    let task = runtime.run(
      RootSagas(
        auth: AuthSagas(useCase: AuthUseCase(repository: InMemoryAuthRepository(latency: .zero))),
        todo: TodoSagas(useCase: TodoUseCase(repository: InMemoryTodoRepository(latency: .zero)))
      ).root)
    await runtime.waitUntilIdle()
    await host.dispatch(.auth(.loggedIn(User(name: "first"))))
    await runtime.waitUntilIdle()
    await host.holdNextRead()
    await host.dispatch(.auth(.loggedOut))
    var reads = host.didRead.makeAsyncIterator()
    _ = await reads.next()
    await host.dispatch(.auth(.loggedIn(User(name: "me"))))
    await host.releaseRead()
    await runtime.waitUntilIdle()
    let actions = await host.dispatched
    #expect(actions.filter { $0 == .todo(.refresh) }.count == 2)
    #expect(actions.contains(.todo(.loaded([], generation: 1))))
    runtime.stop()
    _ = try? await task.join()
  }
}
