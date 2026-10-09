import Domain
import Foundation
import ReduxPersistence
import ReduxTesting
import Testing

@testable import AppFeature

/// 失敗を返すリポジトリ。
private struct FailingRepository: TodoRepository {
  struct Failure: LocalizedError {
    var errorDescription: String? { "offline" }
  }

  func fetchAll() async throws -> [Todo] { throw Failure() }
  func save(_ todo: Todo) async throws { throw Failure() }
  func delete(id: Todo.ID) async throws { throw Failure() }
}

private let milk = Todo(title: "milk", createdAt: Date(timeIntervalSince1970: 0))
private let bread = Todo(title: "bread", createdAt: Date(timeIntervalSince1970: 1))

@MainActor
private func makeStore(_ todos: [Todo] = [milk, bread]) -> TestStore<
  TodoFeature.State, TodoFeature.Action
> {
  // テストではリポジトリの遅れをなくし、Saga の待ち合わせだけで進める。
  let useCase = TodoUseCase(repository: InMemoryTodoRepository(todos: todos, latency: .zero))
  return TestStore(
    initialState: TodoFeature.initialState,
    reducer: TodoFeature.reducer,
    saga: TodoSagas(useCase: useCase).root
  )
}

@MainActor
@Suite struct TodoFeatureTests {
  @Test func theSagaLoadsTodosOnStartInCreationOrder() async throws {
    let store = makeStore()
    await store.settle()
    try store.receive(.refresh) { $0.isLoading = true }
    try store.receive(.loaded([milk, bread])) {
      $0.isLoading = false
      $0.todos.ids = [milk.id, bread.id]
      $0.todos.entities = [milk.id: milk, bread.id: bread]
    }
    try await store.finish()
  }

  @Test func refreshReloadsTodos() async throws {
    let store = makeStore()
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.refresh) { $0.isLoading = true }
    try store.receive(.case { if case .loaded = $0 { () } else { nil } }) { $0.isLoading = false }
    try await store.finish()
  }

  @Test func addAddsATodoWithTheTitle() async throws {
    let store = makeStore([])
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.add(title: "eggs"))
    let added = try store.receive(.case(\.added))
    #expect(added.title == "eggs")
    #expect(TodoFeature.visibleTodos(store.state).map(\.title) == ["eggs"])
    try await store.finish()
  }

  @Test func hidingCompletedTodosFiltersThemOut() async throws {
    var done = bread
    done.isDone = true
    let store = makeStore([milk, done])
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.setShowsCompleted(false)) { $0.preferences.showsCompleted = false }
    #expect(TodoFeature.visibleTodos(store.state) == [milk])
    try await store.finish()
  }

  @Test func toggleTappedSavesTheToggledTodo() async throws {
    let store = makeStore()
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.toggleTapped(milk.id))
    var done = milk
    done.isDone = true
    try store.receive(.updated(done)) { $0.todos.entities[milk.id] = done }
    try await store.finish()
  }

  @Test func deleteTappedRemovesTheTodo() async throws {
    let store = makeStore()
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.deleteTapped(milk.id))
    try store.receive(.deleted(milk.id)) {
      $0.todos.ids = [bread.id]
      $0.todos.entities[milk.id] = nil
    }
    try await store.finish()
  }

  @Test func searchIsAppliedAfterTypingStops() async throws {
    let store = makeStore()
    await store.settle()
    store.skipReceivedActions()
    try await store.send(.binding(.set(\.$query, "m"))) { $0.query = "m" }
    await store.advance(by: .milliseconds(200))
    try await store.send(.binding(.set(\.$query, "mi"))) { $0.query = "mi" }
    await store.advance(by: .milliseconds(300))
    try store.receive(.queryApplied("mi")) { $0.appliedQuery = "mi" }
    #expect(TodoFeature.visibleTodos(store.state) == [milk])
    try await store.finish()
  }

  @Test func failureIsShownAsAnErrorMessage() async throws {
    let store = TestStore(
      initialState: TodoFeature.initialState,
      reducer: TodoFeature.reducer,
      saga: TodoSagas(useCase: TodoUseCase(repository: FailingRepository())).root
    )
    await store.settle()
    try store.receive(.refresh) { $0.isLoading = true }
    try store.receive(.failed("offline")) {
      $0.isLoading = false
      $0.errorMessage = "offline"
    }
    try await store.send(.errorDismissed) { $0.errorMessage = nil }
    try await store.finish()
  }
}

/// 保存に時間がかかる間に続けて操作した場合。
@MainActor
@Suite struct TodoConsecutiveEditTests {
  /// 保存に時間がかかるリポジトリで Store を作り、起動時の読み込みが終わるまで待つ。
  private func makeComponents(_ todos: [Todo]) async -> AppStore.Components {
    let useCase = TodoUseCase(
      repository: InMemoryTodoRepository(todos: todos, latency: .milliseconds(20)))
    let components = AppStore.makeComponents(useCase: useCase, storage: InMemoryStorage())
    await components.sagaMiddleware.waitUntilIdle()
    return components
  }

  @Test func togglingTheSameTodoTwiceWhileSavingEndsWhereItStarted() async {
    let components = await makeComponents([milk])
    // 1 回目の保存が終わる前に 2 回目を押す。
    components.store.dispatch(.toggleTapped(milk.id))
    components.store.dispatch(.toggleTapped(milk.id))
    await components.sagaMiddleware.waitUntilIdle()
    #expect(components.store.todos.entities[milk.id]?.isDone == false)
  }

  @Test func addingWhileAnotherAddIsSavingKeepsBoth() async {
    let components = await makeComponents([])
    components.store.dispatch(.add(title: "eggs"))
    components.store.dispatch(.add(title: "tea"))
    await components.sagaMiddleware.waitUntilIdle()
    #expect(TodoFeature.visibleTodos(components.store.state).map(\.title) == ["eggs", "tea"])
  }
}
