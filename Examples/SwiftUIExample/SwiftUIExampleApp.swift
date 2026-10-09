import AppFeature
import Domain
import Foundation
import Redux
import ReduxSwiftUI
import SwiftUI

/// アプリ本体は View と Store の組み立てだけを持つ。依存（リポジトリ）はここで決めて注入する。
@main
struct SwiftUIExampleApp: App {
  @State private var store = AppStore.make(
    useCase: TodoUseCase(
      repository: InMemoryTodoRepository(todos: [
        Todo(title: "Read the design doc", createdAt: .now.addingTimeInterval(-60)),
        Todo(title: "Write a saga", createdAt: .now),
      ])
    )
  )

  var body: some Scene {
    WindowGroup {
      TabView {
        // MVVM を経由する画面: View は ViewModel だけを見る。ViewModel が Store を読む。
        TodoListView(viewModel: TodoListViewModel(store: store))
          .tabItem { Label("ToDo", systemImage: "checklist") }
        // Store を直接使う画面: 画面特有の状態がない単純な画面は、Store を直接読んで dispatch する。
        SettingsView()
          .tabItem { Label("Settings", systemImage: "gear") }
      }
      .store(store)
    }
  }
}
