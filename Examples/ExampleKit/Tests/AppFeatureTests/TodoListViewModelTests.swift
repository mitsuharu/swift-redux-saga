import Domain
import Foundation
import Redux
import ReduxPersistence
import ReduxSaga
import Testing

@testable import AppFeature

@MainActor
@Suite struct TodoListViewModelTests {
  /// ViewModel を作り、起動時の読み込みが終わるまで待つ。
  private func makeViewModel(storage: InMemoryStorage = InMemoryStorage()) async
    -> (TodoListViewModel, SagaMiddleware<TodoFeature.State, TodoFeature.Action>)
  {
    let useCase = TodoUseCase(repository: InMemoryTodoRepository(latency: .zero))
    let (store, sagaMiddleware) = AppStore.makeComponents(useCase: useCase, storage: storage)
    // 起動時の読み込み（refresh → loaded）を待たずに操作すると、後から届いた loaded が
    // 追加した ToDo を上書きするため、Saga が止まるまで待つ。
    await sagaMiddleware.waitUntilIdle()
    return (TodoListViewModel(store: store), sagaMiddleware)
  }

  @Test func typingADraftEnablesAdding() async {
    let (viewModel, _) = await makeViewModel()
    #expect(!viewModel.canAdd)
    viewModel.draft = "eggs"
    #expect(viewModel.canAdd)
  }

  @Test func addSendsTheDraftAndClearsIt() async {
    let (viewModel, sagaMiddleware) = await makeViewModel()
    viewModel.draft = "  eggs "
    viewModel.add()
    #expect(viewModel.draft == "")
    await sagaMiddleware.waitUntilIdle()
    #expect(viewModel.todos.map(\.title) == ["eggs"])
  }

  @Test func blankDraftCannotBeAdded() async {
    let (viewModel, _) = await makeViewModel()
    viewModel.draft = "   "
    #expect(!viewModel.canAdd)
    viewModel.add()
    #expect(viewModel.draft == "   ")
  }

  @Test func showsCompletedIsPersistedAndRestored() async throws {
    let storage = InMemoryStorage()
    let (viewModel, _) = await makeViewModel(storage: storage)
    viewModel.showsCompleted = false
    #expect(!viewModel.showsCompleted)
    // 保存はメインアクター外で debounce の後に行われる。上限を決めて待ち、待ちすぎたら失敗にする。
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while storage.values.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!storage.values.isEmpty)

    let (restored, _) = await makeViewModel(storage: storage)
    #expect(!restored.showsCompleted)
  }
}
