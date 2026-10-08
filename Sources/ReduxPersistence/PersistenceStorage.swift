import Foundation
import InternalPrimitives

/// 永続化したデータの保存先。
///
/// `UserDefaultsStorage` / `FileStorage` / `InMemoryStorage` を用意しています。Keychain やデータベースに
/// 保存したい場合は、このプロトコルに準拠した型を作ってください。
public protocol PersistenceStorage: Sendable {
  /// 保存したデータを読みます。なければ `nil` を返します。
  func load(key: String) throws -> Data?
  /// データを保存します。
  func save(_ data: Data, key: String) throws
  /// 保存したデータを消します。
  func remove(key: String) throws
}

/// `UserDefaults` に保存する。設定など小さなデータ向け。
public struct UserDefaultsStorage: PersistenceStorage {
  // UserDefaults のインスタンスを持たないのは、Linux の Foundation では Sendable でないため。
  // 操作のたびに suiteName から取り出す。
  private let suiteName: String?

  /// - Parameter suiteName: `UserDefaults(suiteName:)` に渡す名前。`nil` なら `UserDefaults.standard`。
  public init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func load(key: String) throws -> Data? {
    defaults.data(forKey: key)
  }

  public func save(_ data: Data, key: String) throws {
    defaults.set(data, forKey: key)
  }

  public func remove(key: String) throws {
    defaults.removeObject(forKey: key)
  }
}

/// ディレクトリの中に、キーごとのファイルとして保存する。大きなデータ向け。
public struct FileStorage: PersistenceStorage {
  private let directory: URL

  /// - Parameter directory: 保存先のディレクトリ。なければ保存時に作ります。
  public init(directory: URL) {
    self.directory = directory
  }

  private func url(for key: String) -> URL {
    directory.appendingPathComponent(key).appendingPathExtension("json")
  }

  public func load(key: String) throws -> Data? {
    let url = url(for: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  public func save(_ data: Data, key: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 書き込みの途中で終了しても壊れたファイルが残らないよう、一時ファイルに書いてから置き換える。
    try data.write(to: url(for: key), options: .atomic)
  }

  public func remove(key: String) throws {
    let url = url(for: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

/// メモリに保存する。テストやプレビュー向け。
public final class InMemoryStorage: PersistenceStorage {
  private let storage = Locked<[String: Data]>([:])

  public init(_ initial: [String: Data] = [:]) {
    storage.withLock { $0 = initial }
  }

  /// 保存されているデータ。
  public var values: [String: Data] {
    storage.withLock { $0 }
  }

  public func load(key: String) throws -> Data? {
    storage.withLock { $0[key] }
  }

  public func save(_ data: Data, key: String) throws {
    storage.withLock { $0[key] = data }
  }

  public func remove(key: String) throws {
    _ = storage.withLock { $0.removeValue(forKey: key) }
  }
}
