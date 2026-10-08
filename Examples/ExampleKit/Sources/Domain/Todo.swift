import Foundation

/// ToDo。
///
/// Domain は本ライブラリ（Redux / Saga）を import しない。状態管理を差し替えても、このコードはそのまま使える。
public struct Todo: Sendable, Equatable, Identifiable, Codable {
  public var id: UUID
  public var title: String
  public var isDone: Bool
  public var createdAt: Date

  public init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isDone = isDone
    self.createdAt = createdAt
  }
}

/// ToDo の保存先。
public protocol TodoRepository: Sendable {
  func fetchAll() async throws -> [Todo]
  func save(_ todo: Todo) async throws
  func delete(id: Todo.ID) async throws
}

/// ToDo の取得・追加・完了の切り替え・削除。
public struct TodoUseCase: Sendable {
  private let repository: any TodoRepository

  public init(repository: any TodoRepository) {
    self.repository = repository
  }

  /// すべての ToDo を作成日時の順に返す。
  public func load() async throws -> [Todo] {
    try await repository.fetchAll().sorted { $0.createdAt < $1.createdAt }
  }

  /// タイトルから ToDo を作って保存する。前後の空白を除いたタイトルが空なら保存しない。
  public func add(title: String) async throws -> Todo? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    let todo = Todo(title: title)
    try await repository.save(todo)
    return todo
  }

  /// 完了と未完了を切り替えて保存する。
  public func toggle(_ todo: Todo) async throws -> Todo {
    var todo = todo
    todo.isDone.toggle()
    try await repository.save(todo)
    return todo
  }

  public func delete(_ id: Todo.ID) async throws {
    try await repository.delete(id: id)
  }
}

/// メモリに保存するリポジトリ。通信の遅れを再現するため、操作ごとに `latency` だけ待つ。
public actor InMemoryTodoRepository: TodoRepository {
  private var todos: [Todo.ID: Todo]
  private let latency: Duration

  public init(todos: [Todo] = [], latency: Duration = .milliseconds(300)) {
    self.todos = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
    self.latency = latency
  }

  public func fetchAll() async throws -> [Todo] {
    try await Task.sleep(for: latency)
    return Array(todos.values)
  }

  public func save(_ todo: Todo) async throws {
    try await Task.sleep(for: latency)
    todos[todo.id] = todo
  }

  public func delete(id: Todo.ID) async throws {
    try await Task.sleep(for: latency)
    todos[id] = nil
  }
}
