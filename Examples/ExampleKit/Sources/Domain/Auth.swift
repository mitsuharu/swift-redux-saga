import Foundation

/// ログイン中のユーザー。
public struct User: Sendable, Equatable, Codable {
  public var name: String

  public init(name: String) {
    self.name = name
  }
}

/// ログインとログアウト。
public protocol AuthRepository: Sendable {
  func login(name: String) async throws -> User
  func logout() async throws
}

/// ログインとログアウト。名前の前後の空白を除き、空ならログインしない。
public struct AuthUseCase: Sendable {
  private let repository: any AuthRepository

  public init(repository: any AuthRepository) {
    self.repository = repository
  }

  public func login(name: String) async throws -> User? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    return try await repository.login(name: name)
  }

  public func logout() async throws {
    try await repository.logout()
  }
}

/// 通信せずにログインするリポジトリ。通信の遅れを再現するため、操作ごとに `latency` だけ待つ。
public struct InMemoryAuthRepository: AuthRepository {
  private let latency: Duration

  public init(latency: Duration = .milliseconds(300)) {
    self.latency = latency
  }

  public func login(name: String) async throws -> User {
    try await Task.sleep(for: latency)
    return User(name: name)
  }

  public func logout() async throws {
    try await Task.sleep(for: latency)
  }
}
