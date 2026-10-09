import AppFeature
import Domain
import Redux
import ReduxUIKit
import UIKit

/// ViewController は ViewModel だけを見る。Store や Action は ViewModel が扱う。
final class TodoViewController: UIViewController {
  private typealias DataSource = UITableViewDiffableDataSource<Int, Todo.ID>

  private let viewModel: TodoListViewModel
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let draftField = UITextField()
  private let addButton = UIButton(configuration: .filled())
  private let showsCompletedSwitch = UISwitch()
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private var dataSource: DataSource?

  init(viewModel: TodoListViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "ToDo"
    view.backgroundColor = .systemGroupedBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: activityIndicator)
    setUpInput()
    setUpTable()
    observeViewModel()
  }

  private func setUpInput() {
    draftField.placeholder = "New ToDo"
    draftField.borderStyle = .roundedRect
    draftField.accessibilityIdentifier = "draftField"
    draftField.addAction(
      UIAction { [weak self] action in
        guard let field = action.sender as? UITextField else { return }
        self?.viewModel.draft = field.text ?? ""
      },
      for: .editingChanged)

    addButton.setTitle("Add", for: .normal)
    addButton.accessibilityIdentifier = "addButton"
    addButton.addAction(
      UIAction { [weak self] _ in self?.viewModel.add() }, for: .primaryActionTriggered)

    let showsCompletedLabel = UILabel()
    showsCompletedLabel.text = "Show completed"
    showsCompletedSwitch.accessibilityIdentifier = "showsCompletedToggle"
    showsCompletedSwitch.addAction(
      UIAction { [weak self] action in
        guard let toggle = action.sender as? UISwitch else { return }
        self?.viewModel.showsCompleted = toggle.isOn
      },
      for: .valueChanged)

    let inputRow = UIStackView(arrangedSubviews: [draftField, addButton])
    inputRow.spacing = 8
    let optionRow = UIStackView(arrangedSubviews: [showsCompletedLabel, showsCompletedSwitch])
    optionRow.spacing = 8
    let stack = UIStackView(arrangedSubviews: [inputRow, optionRow])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])

    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setUpTable() {
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    tableView.delegate = self
    dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
      let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
      // セルの内容は、その都度 ViewModel（の先の Store）から読む。ViewController に ToDo の写しを持たない。
      guard let todo = self?.viewModel.todo(id) else { return cell }
      var content = cell.defaultContentConfiguration()
      content.text = todo.title
      content.image = UIImage(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
      cell.contentConfiguration = content
      cell.accessibilityIdentifier = "todo-\(todo.title)"
      return cell
    }
    let refreshControl = UIRefreshControl()
    refreshControl.addAction(
      UIAction { [weak self] _ in
        self?.viewModel.refresh()
        refreshControl.endRefreshing()
      },
      for: .valueChanged)
    tableView.refreshControl = refreshControl
  }

  /// ViewModel の変化を画面に反映する（iOS 17 から動く購読 API）。
  ///
  /// iOS 26 以降だけを対象にするなら、`updateProperties()` の中で `viewModel.todos` などを読むだけで
  /// UIKit が自動で追跡するため、この購読は不要になる。
  private func observeViewModel() {
    ObservationToken.observe { [weak viewModel] in
      viewModel?.todos ?? []
    } onChange: {
      [weak self] todos in
      self?.apply(todos)
    }
    .retained(by: self)

    ObservationToken.observe { [weak viewModel] in
      (viewModel?.draft ?? "", viewModel?.canAdd ?? false, viewModel?.showsCompleted ?? true)
    } onChange: { [weak self] draft, canAdd, showsCompleted in
      guard let self else { return }
      if draftField.text != draft { draftField.text = draft }
      addButton.isEnabled = canAdd
      showsCompletedSwitch.isOn = showsCompleted
    }
    .retained(by: self)

    ObservationToken.observe { [weak viewModel] in
      viewModel?.isLoading ?? false
    } onChange: {
      [weak self] isLoading in
      if isLoading {
        self?.activityIndicator.startAnimating()
      } else {
        self?.activityIndicator.stopAnimating()
      }
    }
    .retained(by: self)

    ObservationToken.observe { [weak viewModel] in
      viewModel?.errorMessage
    } onChange: {
      [weak self] message in
      guard let self, let message else { return }
      let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
      alert.addAction(
        UIAlertAction(title: "OK", style: .default) { [weak self] _ in
          self?.viewModel.dismissError()
        })
      present(alert, animated: true)
    }
    .retained(by: self)
  }

  private func apply(_ todos: [Todo]) {
    var snapshot = NSDiffableDataSourceSnapshot<Int, Todo.ID>()
    snapshot.appendSections([0])
    snapshot.appendItems(todos.map(\.id))
    // 完了の切り替えなど、同じ ID の中身が変わった場合も描き直す。
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource?.apply(snapshot, animatingDifferences: true)
  }
}

extension TodoViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
    viewModel.toggle(id)
  }

  func tableView(
    _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
    let delete = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      self?.viewModel.delete(id)
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }
}
