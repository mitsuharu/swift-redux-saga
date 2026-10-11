import AppFeature
import Redux
import ReduxSwiftUI
import SwiftUI

/// ログイン画面。Store を直接使う（入力中の名前は画面特有の状態なので、View の @State に持つ）。
///
/// `@SelectState` / `@DispatchAction` で、State から読む値と Action を送る関数だけを宣言する
/// （React Redux の useSelector / useDispatch に当たる書き方）。
struct LoginView: View {
  @SelectState(\RootFeature.State.auth.isLoggingIn) private var isLoggingIn
  @SelectState(\RootFeature.State.auth.errorMessage) private var errorMessage
  @DispatchAction private var dispatch: (RootFeature.Action) -> Void
  @State private var name = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
          .onSubmit(login)
          .accessibilityIdentifier("nameField")
        Button("Log in", action: login)
          .disabled(isLoggingIn)
          .accessibilityIdentifier("loginButton")
        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .overlay {
        if isLoggingIn {
          ProgressView()
        }
      }
      .navigationTitle("Log in")
    }
  }

  private func login() {
    dispatch(.auth(.loginTapped(name: name)))
  }
}
