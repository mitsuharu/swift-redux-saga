#if canImport(SwiftUI)
  import Redux
  import SwiftUI

  /// `.store(_:id:)` で Environment に入れた Store を、`@SelectState` / `@DispatchAction` から指定するための識別子。
  ///
  /// 文字列リテラルで書けます。綴りの間違いを防ぐため、`static let` で定義しておくことをおすすめします。
  ///
  /// ```swift
  /// extension StoreID {
  ///   static let app: StoreID = "app"
  /// }
  ///
  /// RootView()
  ///   .store(appStore, id: .app)
  ///
  /// // 子の View で
  /// @SelectState(\AppState.user, store: .app) private var user
  /// @DispatchAction(store: .app) private var dispatch: (AppAction) -> Void
  /// ```
  public struct StoreID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// 識別子の文字列。
    public let rawValue: String

    /// 文字列から識別子を作ります。
    public init(_ rawValue: String) {
      self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
      self.init(value)
    }

    public var description: String { rawValue }
  }

  /// 識別子を付けて Environment に入れた、Store の読み取り口と送り口。
  ///
  /// 識別子と型（`StoreSource<State>` / `ActionSink<Action>`）の組で引く。同じ組を内側で入れると、内側が使われる。
  struct NamedStores: Sendable {
    private struct Key: Hashable, Sendable {
      let id: StoreID
      let type: ObjectIdentifier
    }

    // 値は StoreSource / ActionSink（メインアクターに隔離されたクラスなので Sendable）。
    private var entries: [Key: any AnyObject & Sendable] = [:]

    mutating func register<State, Action>(
      _ source: StoreSource<State>, _ sink: ActionSink<Action>, id: StoreID
    ) {
      entries[Key(id: id, type: ObjectIdentifier(StoreSource<State>.self))] = source
      entries[Key(id: id, type: ObjectIdentifier(ActionSink<Action>.self))] = sink
    }

    func source<State>(_: State.Type, id: StoreID) -> StoreSource<State>? {
      entries[Key(id: id, type: ObjectIdentifier(StoreSource<State>.self))] as? StoreSource<State>
    }

    func sink<Action>(_: Action.Type, id: StoreID) -> ActionSink<Action>? {
      entries[Key(id: id, type: ObjectIdentifier(ActionSink<Action>.self))] as? ActionSink<Action>
    }
  }

  private struct NamedStoresKey: EnvironmentKey {
    static let defaultValue = NamedStores()
  }

  extension EnvironmentValues {
    var namedStores: NamedStores {
      get { self[NamedStoresKey.self] }
      set { self[NamedStoresKey.self] = newValue }
    }
  }

  extension View {
    /// 識別子を付けて Store を Environment に入れます。子の View では、`@SelectState(..., store: id)` /
    /// `@DispatchAction(store: id)` で、この Store を指定して読み書きできます。
    ///
    /// 型だけで探す `.store(_:)` と違い、同じ型の Store を入れ子にしても、識別子で区別できます。
    /// 識別子を付けた Store は、識別子を指定しない `@SelectState` / `@DispatchAction` や
    /// `@Environment(Store<State, Action>.self)` からは見えません（外側の `.store(_:)` を上書きしないため）。
    /// 両方から使いたい場合は、`.store(_:)` も付けてください。
    public func store<State: Sendable, Action: Sendable>(
      _ store: Store<State, Action>, id: StoreID
    ) -> some View {
      let (source, sink) = (StoreSource(store), ActionSink(store))
      return transformEnvironment(\.namedStores) { $0.register(source, sink, id: id) }
    }
  }
#endif
