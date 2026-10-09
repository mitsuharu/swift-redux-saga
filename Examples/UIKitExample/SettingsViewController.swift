import AppFeature
import Redux
import ReduxUIKit
import UIKit

/// Store を直接使う画面の例。
///
/// 画面特有の状態がなく、Store の値を表示して dispatch するだけの単純な画面は、ViewModel を挟まずに
/// Store を直接使う。iOS 17 から動くよう、store.observe で変化を反映する。
final class SettingsViewController: UIViewController {
  private let store: Store<RootFeature.State, RootFeature.Action>
  private let showsCompletedSwitch = UISwitch()
  private let summaryLabel = UILabel()

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
    title = "Settings"
    view.backgroundColor = .systemGroupedBackground

    let showsCompletedLabel = UILabel()
    showsCompletedLabel.text = "Show completed"
    showsCompletedSwitch.accessibilityIdentifier = "settingsShowsCompletedToggle"
    showsCompletedSwitch.addAction(
      UIAction { [weak self] action in
        guard let toggle = action.sender as? UISwitch else { return }
        self?.store.dispatch(.todo(.setShowsCompleted(toggle.isOn)))
      },
      for: .valueChanged)

    // ボタンから Action を dispatch するだけなら、store.action で UIAction を作れる。
    let reloadButton = UIButton(
      configuration: .bordered(), primaryAction: store.action(.todo(.refresh), title: "Reload"))
    reloadButton.accessibilityIdentifier = "reloadButton"
    // ログアウトすると、ToDo の Saga が止まり、一覧が消えてログイン画面に戻る。
    let logoutButton = UIButton(
      configuration: .bordered(),
      primaryAction: store.action(.auth(.logoutTapped), title: "Log out"))
    logoutButton.accessibilityIdentifier = "logoutButton"

    let row = UIStackView(arrangedSubviews: [showsCompletedLabel, showsCompletedSwitch])
    row.spacing = 8
    let stack = UIStackView(arrangedSubviews: [row, summaryLabel, reloadButton, logoutButton])
    stack.axis = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])

    store.observe {
      $0.todo.preferences.showsCompleted
    } onChange: { [weak self] showsCompleted in
      self?.showsCompletedSwitch.isOn = showsCompleted
    }
    .retained(by: self)

    store.observe {
      $0.todo.todos
    } onChange: { [weak self] todos in
      let completed = todos.entities.values.filter(\.isDone).count
      self?.summaryLabel.text = "All: \(todos.ids.count) / Completed: \(completed)"
    }
    .retained(by: self)
  }
}
