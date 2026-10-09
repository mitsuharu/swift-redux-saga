import AppFeature
import Redux
import SwiftUI

/// ログイン画面。Store を直接使う（入力中の名前は画面特有の状態なので、View の @State に持つ）。
struct LoginView: View {
  @Environment(Store<RootFeature.State, RootFeature.Action>.self) private var store
  @State private var name = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
          .onSubmit(login)
          .accessibilityIdentifier("nameField")
        Button("Log in", action: login)
          .disabled(store.auth.isLoggingIn)
          .accessibilityIdentifier("loginButton")
        if let message = store.auth.errorMessage {
          Text(message).foregroundStyle(.red)
        }
      }
      .overlay {
        if store.auth.isLoggingIn {
          ProgressView()
        }
      }
      .navigationTitle("Log in")
    }
  }

  private func login() {
    store.dispatch(.auth(.loginTapped(name: name)))
  }
}
