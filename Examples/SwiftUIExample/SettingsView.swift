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
  @Environment(Store<TodoFeature.State, TodoFeature.Action>.self) private var store

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          // 値を書き戻すだけの入力欄は store.binding で作る（設定は永続化される）。
          Toggle(
            "Show completed",
            isOn: store.binding(\.preferences.showsCompleted, send: { .setShowsCompleted($0) })
          )
          .accessibilityIdentifier("settingsShowsCompletedToggle")
        }
        Section("Summary") {
          LabeledContent("All", value: "\(store.todos.ids.count)")
          LabeledContent(
            "Completed",
            value: "\(store.todos.entities.values.filter(\.isDone).count)")
        }
        Section {
          Button("Reload") { store.dispatch(.refresh) }
            .disabled(store.isLoading)
            .accessibilityIdentifier("reloadButton")
        }
      }
      .navigationTitle("Settings")
    }
  }
}
