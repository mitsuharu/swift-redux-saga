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
      // 画面には ViewModel を渡す（MVVM と併用する）。ViewModel が Store を読む。
      TodoListView(viewModel: TodoListViewModel(store: store))
    }
  }
}
