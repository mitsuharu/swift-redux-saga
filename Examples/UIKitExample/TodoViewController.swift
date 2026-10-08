import AppFeature
import Domain
import Redux
import ReduxUIKit
import UIKit

final class TodoViewController: UIViewController {
  private typealias DataSource = UITableViewDiffableDataSource<Int, Todo.ID>

  private let store: Store<TodoFeature.State, TodoFeature.Action>
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let draftField = UITextField()
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private var dataSource: DataSource?

  init(store: Store<TodoFeature.State, TodoFeature.Action>) {
    self.store = store
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
    observeStore()
  }

  private func setUpInput() {
    draftField.placeholder = "New ToDo"
    draftField.borderStyle = .roundedRect
    draftField.accessibilityIdentifier = "draftField"
    draftField.addAction(
      UIAction { [weak self] action in
        guard let self, let field = action.sender as? UITextField else { return }
        store.dispatch(.binding(.set(\.$draft, field.text ?? "")))
      },
      for: .editingChanged)

    let addButton = UIButton(
      configuration: .filled(), primaryAction: store.action(.addTapped, title: "Add"))
    addButton.accessibilityIdentifier = "addButton"

    let stack = UIStackView(arrangedSubviews: [draftField, addButton])
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
      guard let todo = self?.store.todos.entities[id] else { return cell }
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
        self?.store.dispatch(.refresh)
        refreshControl.endRefreshing()
      },
      for: .valueChanged)
    tableView.refreshControl = refreshControl
  }

  /// OS に依存しない購読 API で State の変化を画面に反映する。
  ///
  /// iOS 26 以降だけを対象にするなら、`updateProperties()` の中で `store.todos` などを読むだけで
  /// UIKit が自動で追跡するため、この購読は不要になる。
  private func observeStore() {
    store.observe {
      $0.todos
    } onChange: { [weak self] _ in
      self?.applySnapshot()
    }
    .retained(by: self)

    store.observe {
      $0.isLoading
    } onChange: { [weak self] isLoading in
      if isLoading {
        self?.activityIndicator.startAnimating()
      } else {
        self?.activityIndicator.stopAnimating()
      }
    }
    .retained(by: self)

    store.observe {
      $0.draft
    } onChange: { [weak self] draft in
      if self?.draftField.text != draft { self?.draftField.text = draft }
    }
    .retained(by: self)

    store.observe {
      $0.errorMessage
    } onChange: { [weak self] message in
      guard let self, let message else { return }
      let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
      alert.addAction(
        UIAlertAction(title: "OK", style: .default) { [weak self] _ in
          self?.store.dispatch(.errorDismissed)
        })
      present(alert, animated: true)
    }
    .retained(by: self)
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Int, Todo.ID>()
    snapshot.appendSections([0])
    snapshot.appendItems(TodoFeature.visibleTodos(store.state).map(\.id))
    // 完了の切り替えなど、同じ ID の中身が変わった場合も描き直す。
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource?.apply(snapshot, animatingDifferences: true)
  }
}

extension TodoViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
    store.dispatch(.toggleTapped(id))
  }

  func tableView(
    _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
    let delete = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      self?.store.dispatch(.deleteTapped(id))
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }
}
