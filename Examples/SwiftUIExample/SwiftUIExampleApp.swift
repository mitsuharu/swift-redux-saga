import AppFeature
import Domain
import Foundation
import Redux
import ReduxSwiftUI
import SwiftUI

/// アプリ本体は View と Store の組み立てだけを持つ。依存（リポジトリ）はここで決めて注入する。
@main
struct SwiftUIExampleApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var app = AppStore.make(
    useCase: TodoUseCase(
      repository: InMemoryTodoRepository(todos: [
        Todo(title: "Read the design doc", createdAt: .now.addingTimeInterval(-60)),
        Todo(title: "Write a saga", createdAt: .now),
      ])
    )
  )

  var body: some Scene {
    WindowGroup {
      RootView(store: app.store)
        .store(app.store)
    }
    .onChange(of: scenePhase) { _, phase in
      // 設定は少し待ってから保存するため、その間に終了されないよう、バックグラウンドに入ったらすぐ保存する。
      if phase == .background {
        Task { await app.flush() }
      }
    }
  }
}

/// ログインしていなければログイン画面を、していれば ToDo と設定のタブを表示する。
private struct RootView: View {
  let store: Store<RootFeature.State, RootFeature.Action>

  var body: some View {
    if store.auth.user == nil {
      LoginView()
    } else {
      TabView {
        // MVVM を経由する画面: View は ViewModel だけを見る。ViewModel が Store を読む。
        // ViewModel には ToDo の機能の Store（scope したもの）を渡し、アプリ全体の型を知らせない。
        TodoListView(
          viewModel: TodoListViewModel(
            store: store.scope(state: \.todo, action: RootFeature.Action.todo))
        )
        .tabItem { Label("ToDo", systemImage: "checklist") }
        // Store を直接使う画面: 画面特有の状態がない単純な画面は、Store を直接読んで dispatch する。
        SettingsView()
          .tabItem { Label("Settings", systemImage: "gear") }
      }
    }
  }
}
