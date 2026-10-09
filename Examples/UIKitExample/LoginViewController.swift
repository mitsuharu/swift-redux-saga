import AppFeature
import Redux
import ReduxUIKit
import UIKit

/// ログイン画面。Store を直接使う（入力中の名前はテキストフィールドが持つ）。
final class LoginViewController: UIViewController {
  private let store: Store<RootFeature.State, RootFeature.Action>
  private let nameField = UITextField()
  private let loginButton = UIButton(configuration: .borderedProminent())
  private let messageLabel = UILabel()

  init(store: Store<RootFeature.State, RootFeature.Action>) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Log in"
    view.backgroundColor = .systemGroupedBackground

    nameField.placeholder = "Name"
    nameField.borderStyle = .roundedRect
    nameField.accessibilityIdentifier = "nameField"
    loginButton.configuration?.title = "Log in"
    loginButton.accessibilityIdentifier = "loginButton"
    loginButton.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        store.dispatch(.auth(.loginTapped(name: nameField.text ?? "")))
      },
      for: .primaryActionTriggered)
    messageLabel.textColor = .systemRed

    let stack = UIStackView(arrangedSubviews: [nameField, loginButton, messageLabel])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])

    store.observe {
      ($0.auth.isLoggingIn, $0.auth.errorMessage)
    } onChange: { [weak self] isLoggingIn, errorMessage in
      self?.loginButton.isEnabled = !isLoggingIn
      self?.messageLabel.text = errorMessage
    }
    .retained(by: self)
  }
}
