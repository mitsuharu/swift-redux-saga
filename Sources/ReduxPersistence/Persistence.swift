import Foundation

/// State の一部（スナップショット）を保存し、起動時に復元するための設定。
///
/// ```swift
/// let persistence = Persistence<AppState, [Todo]>(
///   key: "todos",
///   storage: FileStorage(directory: .applicationSupportDirectory),
///   keyPath: \.todos
/// )
///
/// // 起動時に復元した State で Store を作り、変化したら PersistenceMiddleware が保存する
/// let store = Store(
///   initialState: persistence.restore(into: AppState()),
///   reducer: appReducer,
///   middleware: [PersistenceMiddleware<AppState, AppAction>(persistence)]
/// )
/// ```
///
/// 保存するのは、保存してよいもの（ユーザーの設定や下書きなど）に絞ってください。読み込み中かどうかや
/// エラーのような一時的な状態は保存しません。
public struct Persistence<State: Sendable, Snapshot: Codable & Sendable>: Sendable {
  /// 保存先のキー。
  public let key: String
  /// 保存形式のバージョン。保存形式を変えたら上げ、`migrate` で古い形式から変換してください。
  public let version: Int
  private let storage: any PersistenceStorage
  private let snapshot: @Sendable (State) -> Snapshot
  private let apply: @Sendable (inout State, Snapshot) -> Void
  private let migrate: @Sendable (_ fromVersion: Int, _ data: Data) throws -> Snapshot?

  /// 設定を作ります。
  ///
  /// - Parameters:
  ///   - key: 保存先のキー。
  ///   - storage: 保存先。
  ///   - version: 保存形式のバージョン。
  ///   - snapshot: State から保存する値を取り出す関数。
  ///   - apply: 復元した値を State に反映する関数。
  ///   - migrate: 古いバージョンで保存したデータ（`snapshot` の JSON）を変換する関数。
  ///     変換できなければ `nil` を返します（復元せず、初期の State のまま使います）。
  public init(
    key: String,
    storage: some PersistenceStorage,
    version: Int = 1,
    snapshot: @escaping @Sendable (State) -> Snapshot,
    apply: @escaping @Sendable (inout State, Snapshot) -> Void,
    migrate: @escaping @Sendable (_ fromVersion: Int, _ data: Data) throws -> Snapshot? = {
      _, _ in nil
    }
  ) {
    self.key = key
    self.storage = storage
    self.version = version
    self.snapshot = snapshot
    self.apply = apply
    self.migrate = migrate
  }

  /// State のプロパティ（キーパス）を保存する設定を作ります。
  public init(
    key: String,
    storage: some PersistenceStorage,
    version: Int = 1,
    keyPath: WritableKeyPath<State, Snapshot> & Sendable,
    migrate: @escaping @Sendable (_ fromVersion: Int, _ data: Data) throws -> Snapshot? = {
      _, _ in nil
    }
  ) {
    self.init(
      key: key, storage: storage, version: version,
      snapshot: { $0[keyPath: keyPath] },
      apply: { $0[keyPath: keyPath] = $1 },
      migrate: migrate)
  }

  /// State から保存する値を取り出します。
  public func snapshot(of state: State) -> Snapshot {
    snapshot(state)
  }

  /// 保存した値を `state` に反映して返します。
  ///
  /// 保存したデータがない、読めない、または変換できない場合は、`state` をそのまま返します。
  ///
  /// - Parameters:
  ///   - state: 保存した値を反映する State（初期値）。
  ///   - onError: 読み込みや変換に失敗したときに呼ぶ関数（ログ出力など）。
  public func restore(
    into state: State, onError: (any Error) -> Void = { _ in }
  ) -> State {
    do {
      guard let restored = try load() else { return state }
      var state = state
      apply(&state, restored)
      return state
    } catch {
      onError(error)
      return state
    }
  }

  /// 保存した値を読みます。保存したデータがなければ `nil` を返します。
  public func load() throws -> Snapshot? {
    guard let data = try storage.load(key: key) else { return nil }
    let savedVersion = try JSONDecoder().decode(VersionOnly.self, from: data).version
    if savedVersion == version {
      return try JSONDecoder().decode(Envelope<Snapshot>.self, from: data).snapshot
    }
    // 古い形式は型が分からないので、JSONSerialization でスナップショットの部分だけを取り出して渡す
    // （Codable の型で読み直さないのは、数値の精度などを変えずに渡すため）。
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let snapshot = object["snapshot"]
    else { return nil }
    let body = try JSONSerialization.data(withJSONObject: snapshot, options: [.fragmentsAllowed])
    return try migrate(savedVersion, body)
  }

  /// State から取り出した値を保存します。
  public func save(_ state: State) throws {
    try save(snapshot: snapshot(state))
  }

  /// 値を保存します。
  public func save(snapshot: Snapshot) throws {
    let data = try JSONEncoder().encode(Envelope(version: version, snapshot: snapshot))
    try storage.save(data, key: key)
  }

  /// 保存した値を消します。
  public func clear() throws {
    try storage.remove(key: key)
  }

  /// 保存形式。バージョンを一緒に保存し、読み込み時に変換が必要かを判断する。
  private struct Envelope<Body: Codable>: Codable {
    let version: Int
    let snapshot: Body
  }

  private struct VersionOnly: Decodable {
    let version: Int
  }
}

extension Persistence where Snapshot == State, State: Codable {
  /// State 全体を保存する設定を作ります。
  public init(
    key: String,
    storage: some PersistenceStorage,
    version: Int = 1,
    migrate: @escaping @Sendable (_ fromVersion: Int, _ data: Data) throws -> State? = {
      _, _ in nil
    }
  ) {
    self.init(
      key: key, storage: storage, version: version,
      snapshot: { $0 }, apply: { $0 = $1 }, migrate: migrate)
  }
}
