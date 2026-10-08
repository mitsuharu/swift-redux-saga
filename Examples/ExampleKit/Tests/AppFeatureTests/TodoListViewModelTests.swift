import AppFeature
import Domain
import Foundation
import Redux
import ReduxPersistence
import Testing

@MainActor
@Suite struct TodoListViewModelTests {
  private func makeViewModel(storage: InMemoryStorage = InMemoryStorage()) -> (
    TodoListViewModel, Store<TodoFeature.State, TodoFeature.Action>
  ) {
    let useCase = TodoUseCase(repository: InMemoryTodoRepository(latency: .zero))
    let store = AppStore.make(useCase: useCase, storage: storage)
    return (TodoListViewModel(store: store), store)
  }

  /// Store の値が条件を満たすまで待つ（Saga と保存はメインアクターの外で進むため）。
  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    while !condition() { await Task.yield() }
  }

  @Test func typingADraftEnablesAdding() {
    let (viewModel, _) = makeViewModel()
    #expect(!viewModel.canAdd)
    viewModel.draft = "eggs"
    #expect(viewModel.canAdd)
  }

  @Test func addSendsTheDraftAndClearsIt() async {
    let (viewModel, _) = makeViewModel()
    await waitUntil { !viewModel.isLoading }
    viewModel.draft = "  eggs "
    viewModel.add()
    #expect(viewModel.draft == "")
    await waitUntil { viewModel.todos.map(\.title) == ["eggs"] }
  }

  @Test func blankDraftCannotBeAdded() {
    let (viewModel, _) = makeViewModel()
    viewModel.draft = "   "
    #expect(!viewModel.canAdd)
    viewModel.add()
    #expect(viewModel.draft == "   ")
  }

  @Test func showsCompletedIsPersistedAndRestored() async throws {
    let storage = InMemoryStorage()
    let (viewModel, _) = makeViewModel(storage: storage)
    viewModel.showsCompleted = false
    #expect(!viewModel.showsCompleted)
    await waitUntil { !storage.values.isEmpty }

    let (restored, _) = makeViewModel(storage: storage)
    #expect(!restored.showsCompleted)
  }
}
