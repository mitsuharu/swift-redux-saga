import AppFeature
import Domain
import Redux
import ReduxSwiftUI
import SwiftUI

struct TodoListView: View {
  @Environment(Store<TodoFeature.State, TodoFeature.Action>.self) private var store

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("New ToDo", text: store.binding(\.$draft))
              .onSubmit { store.dispatch(.addTapped) }
              .accessibilityIdentifier("draftField")
            Button("Add") { store.dispatch(.addTapped) }
              .disabled(store.draft.isEmpty)
              .accessibilityIdentifier("addButton")
          }
        }
        Section {
          // 一覧は検索語で絞り込んだ結果（createSelector でメモ化）。
          ForEach(TodoFeature.visibleTodos(store.state)) { todo in
            TodoRow(todo: todo) { store.dispatch(.toggleTapped(todo.id)) }
          }
          .onDelete { offsets in
            let todos = TodoFeature.visibleTodos(store.state)
            for offset in offsets {
              store.dispatch(.deleteTapped(todos[offset].id))
            }
          }
        }
      }
      .overlay {
        if store.isLoading {
          ProgressView()
        }
      }
      .navigationTitle("ToDo")
      .searchable(text: store.binding(\.$query))
      .refreshable { store.dispatch(.refresh) }
      .alert(
        "Error",
        isPresented: Binding(
          get: { store.errorMessage != nil },
          set: { if !$0 { store.dispatch(.errorDismissed) } }
        )
      ) {
        Button("OK") { store.dispatch(.errorDismissed) }
      } message: {
        Text(store.errorMessage ?? "")
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
  TodoListView()
    .store(AppStore.make(useCase: TodoUseCase(repository: InMemoryTodoRepository(latency: .zero))))
}
