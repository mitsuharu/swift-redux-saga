import AppFeature
import Redux
import ReduxSwiftUI
import SwiftUI

/// Store を直接使う画面の例。
///
/// 画面特有の状態がなく、Store の値を表示して dispatch するだけの単純な画面は、ViewModel を挟まずに
/// Store を直接使う。`store.count` のように読んだプロパティだけが追跡されるので、
/// ほかのプロパティが変わってもこの画面は再描画されない。
struct SettingsView: View {
  @Environment(Store<RootFeature.State, RootFeature.Action>.self) private var store

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          // 値を書き戻すだけの入力欄は store.binding で作る（設定は永続化される）。
          Toggle(
            "Show completed",
            isOn: store.binding(\.todo.preferences.showsCompleted) {
              .todo(.setShowsCompleted($0))
            }
          )
          .accessibilityIdentifier("settingsShowsCompletedToggle")
        }
        Section("Summary") {
          LabeledContent("All", value: "\(store.todo.todos.ids.count)")
          LabeledContent(
            "Completed",
            value: "\(store.todo.todos.entities.values.filter(\.isDone).count)")
        }
        Section {
          Button("Reload") { store.dispatch(.todo(.refresh)) }
            .disabled(store.todo.isLoading)
            .accessibilityIdentifier("reloadButton")
        }
        Section("Account") {
          LabeledContent("User", value: store.auth.user?.name ?? "")
          // ログアウトすると、ToDo の Saga が止まり、一覧が消えてログイン画面に戻る。
          Button("Log out", role: .destructive) { store.dispatch(.auth(.logoutTapped)) }
            .accessibilityIdentifier("logoutButton")
        }
      }
      .navigationTitle("Settings")
    }
  }
}
