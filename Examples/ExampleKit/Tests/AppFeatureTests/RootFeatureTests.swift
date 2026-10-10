import AppFeature
import Domain
import Foundation
import Redux
import ReduxTesting
import Testing

private let milk = Todo(title: "milk", createdAt: Date(timeIntervalSince1970: 0))

/// ログインと ToDo を組み合わせた、アプリ全体の Saga。
@MainActor
@Suite struct RootFeatureTests {
  private func makeStore() -> TestStore<RootFeature.State, RootFeature.Action> {
    TestStore(
      initialState: RootFeature.initialState,
      reducer: RootFeature.reducer,
      saga: RootSagas(
        auth: AuthSagas(useCase: AuthUseCase(repository: InMemoryAuthRepository(latency: .zero))),
        todo: TodoSagas(
          useCase: TodoUseCase(repository: InMemoryTodoRepository(todos: [milk], latency: .zero)))
      ).root)
  }

  @Test func todosAreLoadedOnlyAfterLoggingIn() async throws {
    let store = makeStore()
    await store.settle()
    #expect(store.unreceivedActions.isEmpty)

    try await store.send(.auth(.loginTapped(name: "me"))) { $0.auth.isLoggingIn = true }
    try store.receive(.auth(.loggedIn(User(name: "me")))) {
      $0.auth.isLoggingIn = false
      $0.auth.user = User(name: "me")
    }
    try store.receive(.todo(.refresh)) { $0.todo.isLoading = true }
    try store.receive(.todo(.loaded([milk], generation: 0))) {
      $0.todo.isLoading = false
      $0.todo.todos.ids = [milk.id]
      $0.todo.todos.entities = [milk.id: milk]
    }
    try await store.finish()
  }

  @Test func loggingOutStopsTheTodoSagasAndLoggingInAgainRestartsThem() async throws {
    let store = makeStore()
    try await store.send(.auth(.loginTapped(name: "me")))
    store.skipReceivedActions()

    try await store.send(.auth(.logoutTapped))
    try store.receive(.auth(.loggedOut)) {
      $0.auth.user = nil
      $0.todo.todos = EntityState()
      $0.todo.generation = 1
    }
    // ログアウト中は ToDo の Saga が止まっているので、送っても何も起きない。
    try await store.send(.todo(.add(title: "eggs")))
    #expect(store.unreceivedActions.isEmpty)

    try await store.send(.auth(.loginTapped(name: "me")))
    _ = try store.receive(.case(\.auth?.loggedIn))
    try store.receive(.todo(.refresh))
    try store.receive(.todo(.loaded([milk], generation: 1)))
    try await store.finish()
  }

  @Test func aResultOfTheSessionBeforeLoggingOutIsDiscarded() async throws {
    let store = makeStore()
    try await store.send(.auth(.loginTapped(name: "me")))
    store.skipReceivedActions()
    try await store.send(.auth(.logoutTapped))
    store.skipReceivedActions()
    // 通信が終わってから put するまでの間にログアウトされ、前のセッション（世代 0）の結果が届いた。
    try await store.send(.todo(.loaded([milk], generation: 0)))
    #expect(store.state.todo.todos.ids.isEmpty)
    try await store.finish()
  }
}
