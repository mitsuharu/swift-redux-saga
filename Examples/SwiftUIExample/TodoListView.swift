import AppFeature
import Domain
import SwiftUI

/// View は ViewModel だけを見る。Store や Action は ViewModel が扱う。
struct TodoListView: View {
  @State var viewModel: TodoListViewModel

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("New ToDo", text: $viewModel.draft)
              .onSubmit { viewModel.add() }
              .accessibilityIdentifier("draftField")
            Button("Add") { viewModel.add() }
              .disabled(!viewModel.canAdd)
              .accessibilityIdentifier("addButton")
          }
          Toggle("Show completed", isOn: $viewModel.showsCompleted)
            .accessibilityIdentifier("showsCompletedToggle")
        }
        Section {
          ForEach(viewModel.todos) { todo in
            TodoRow(todo: todo) { viewModel.toggle(todo.id) }
          }
          .onDelete { offsets in
            let todos = viewModel.todos
            for offset in offsets {
              viewModel.delete(todos[offset].id)
            }
          }
        }
      }
      .overlay {
        if viewModel.isLoading {
          ProgressView()
        }
      }
      .navigationTitle("ToDo")
      .searchable(text: $viewModel.query)
      .refreshable { viewModel.refresh() }
      .alert(
        "Error",
        isPresented: Binding(
          get: { viewModel.errorMessage != nil },
          set: { if !$0 { viewModel.dismissError() } }
        )
      ) {
        Button("OK") { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage ?? "")
      }
    }
  }
}

private struct TodoRow: View {
  let todo: Todo
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack {
        Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
        Text(todo.title)
          .strikethrough(todo.isDone)
      }
    }
    .foregroundStyle(.primary)
    .accessibilityIdentifier("todo-\(todo.title)")
  }
}

#Preview {
  TodoListView(
    viewModel: TodoListViewModel(
      store: AppStore.make(
        useCase: TodoUseCase(repository: InMemoryTodoRepository(latency: .zero))
      ).store.scope(state: \.todo, action: RootFeature.Action.todo)))
}
