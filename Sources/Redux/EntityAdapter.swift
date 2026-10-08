/// エンティティを ID の並び（`ids`）と ID ごとの辞書（`entities`）で持つ State（Redux Toolkit の正規化された形）。
///
/// ``EntityAdapter`` で読み書きします。
public struct EntityState<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  /// エンティティの ID の並び。``EntityAdapter`` に並び順を指定した場合は、その順に並びます。
  public var ids: [ID]
  /// ID ごとのエンティティ。
  public var entities: [ID: Entity]

  /// 空の State を作ります。
  public init() {
    ids = []
    entities = [:]
  }
}

extension EntityState: Equatable where Entity: Equatable {}

/// ``EntityState`` を読み書きする関数をまとめたもの（Redux Toolkit の `createEntityAdapter` 相当）。
///
/// reducer の中で使います。
///
/// ```swift
/// let todosAdapter = EntityAdapter<Todo.ID, Todo>(sortedBy: { $0.createdAt < $1.createdAt })
///
/// static func reduce(into state: inout State, action: Action) {
///   switch action {
///   case .loaded(let todos): todosAdapter.setAll(todos, in: &state.todos)
///   case .added(let todo): todosAdapter.addOne(todo, to: &state.todos)
///   case .toggled(let id): todosAdapter.updateOne(id, in: &state.todos) { $0.done.toggle() }
///   case .removed(let id): todosAdapter.removeOne(id, from: &state.todos)
///   }
/// }
/// ```
public struct EntityAdapter<ID: Hashable & Sendable, Entity: Sendable>: Sendable {
  private let id: @Sendable (Entity) -> ID
  private let areInIncreasingOrder: (@Sendable (Entity, Entity) -> Bool)?

  /// アダプタを作ります。
  ///
  /// - Parameters:
  ///   - id: エンティティの ID を返す関数。キーパス（`\Todo.id`）も渡せます。
  ///   - sortedBy: `ids` の並び順。省略すると追加した順になります。
  public init(
    id: @escaping @Sendable (Entity) -> ID,
    sortedBy areInIncreasingOrder: (@Sendable (Entity, Entity) -> Bool)? = nil
  ) {
    self.id = id
    self.areInIncreasingOrder = areInIncreasingOrder
  }

  // MARK: - 追加

  /// エンティティを追加します。同じ ID のエンティティがあれば何もしません。
  public func addOne(_ entity: Entity, to state: inout EntityState<ID, Entity>) {
    addMany(CollectionOfOne(entity), to: &state)
  }

  /// エンティティをまとめて追加します。同じ ID のエンティティがあるものは追加しません。
  public func addMany(_ entities: some Sequence<Entity>, to state: inout EntityState<ID, Entity>) {
    for entity in entities {
      let key = id(entity)
      guard state.entities[key] == nil else { continue }
      state.entities[key] = entity
      state.ids.append(key)
    }
    sort(&state)
  }

  // MARK: - 置き換え

  /// エンティティを追加するか、同じ ID のエンティティを置き換えます（Redux Toolkit の `setOne` / `upsertOne`）。
  public func setOne(_ entity: Entity, in state: inout EntityState<ID, Entity>) {
    setMany(CollectionOfOne(entity), in: &state)
  }

  /// エンティティをまとめて追加するか、同じ ID のエンティティを置き換えます。
  public func setMany(_ entities: some Sequence<Entity>, in state: inout EntityState<ID, Entity>) {
    for entity in entities {
      let key = id(entity)
      if state.entities.updateValue(entity, forKey: key) == nil {
        state.ids.append(key)
      }
    }
    sort(&state)
  }

  /// すべてのエンティティを置き換えます。
  public func setAll(_ entities: some Sequence<Entity>, in state: inout EntityState<ID, Entity>) {
    state = EntityState()
    setMany(entities, in: &state)
  }

  // MARK: - 更新

  /// ID のエンティティを更新します。エンティティがなければ何もしません。
  ///
  /// 更新で ID が変わった場合は、新しい ID で持ち直します。
  public func updateOne(
    _ key: ID, in state: inout EntityState<ID, Entity>, _ update: (inout Entity) -> Void
  ) {
    updateMany([key], in: &state, update)
  }

  /// 複数の ID のエンティティを更新します。エンティティがない ID は無視します。
  public func updateMany(
    _ keys: some Sequence<ID>, in state: inout EntityState<ID, Entity>,
    _ update: (inout Entity) -> Void
  ) {
    for key in keys {
      guard var entity = state.entities[key] else { continue }
      update(&entity)
      let newKey = id(entity)
      if newKey != key {
        state.entities[key] = nil
        if let index = state.ids.firstIndex(of: key) { state.ids[index] = newKey }
      }
      state.entities[newKey] = entity
    }
    sort(&state)
  }

  // MARK: - 削除

  /// ID のエンティティを削除します。
  public func removeOne(_ key: ID, from state: inout EntityState<ID, Entity>) {
    removeMany([key], from: &state)
  }

  /// 複数の ID のエンティティを削除します。
  public func removeMany(_ keys: some Sequence<ID>, from state: inout EntityState<ID, Entity>) {
    let keys = Set(keys)
    for key in keys {
      state.entities[key] = nil
    }
    state.ids.removeAll { keys.contains($0) }
  }

  /// すべてのエンティティを削除します。
  public func removeAll(from state: inout EntityState<ID, Entity>) {
    state = EntityState()
  }

  // MARK: - 読み取り

  /// すべてのエンティティを `ids` の順で返します。
  public func all(in state: EntityState<ID, Entity>) -> [Entity] {
    state.ids.compactMap { state.entities[$0] }
  }

  /// ID のエンティティを返します。
  public func entity(_ key: ID, in state: EntityState<ID, Entity>) -> Entity? {
    state.entities[key]
  }

  /// エンティティの数を返します。
  public func count(in state: EntityState<ID, Entity>) -> Int {
    state.ids.count
  }

  private func sort(_ state: inout EntityState<ID, Entity>) {
    guard let areInIncreasingOrder else { return }
    let entities = state.entities
    state.ids.sort { lhs, rhs in
      guard let lhs = entities[lhs], let rhs = entities[rhs] else { return false }
      return areInIncreasingOrder(lhs, rhs)
    }
  }
}

extension EntityAdapter where Entity: Identifiable, ID == Entity.ID {
  /// `Identifiable` なエンティティのアダプタを作ります。ID には `id` を使います。
  ///
  /// - Parameter sortedBy: `ids` の並び順。省略すると追加した順になります。
  public init(sortedBy areInIncreasingOrder: (@Sendable (Entity, Entity) -> Bool)? = nil) {
    self.init(id: { $0.id }, sortedBy: areInIncreasingOrder)
  }
}
