#if canImport(SwiftUI)
  import Redux
  import SwiftUI

  extension Store {
    /// State の値と、値が変わったときに dispatch する Action から `Binding` を作ります。
    ///
    /// 読み取りは ``Redux/Store`` の dynamic member と同じく、このプロパティだけが追跡されます。
    ///
    /// ```swift
    /// TextField("Name", text: store.binding(\.name, send: { .rename($0) }))
    /// Toggle("Done", isOn: store.binding(\.isDone, send: AppAction.setDone))
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: State の中の値。
    ///   - send: 新しい値から dispatch する Action を作る関数。
    public func binding<Value: Equatable>(
      _ keyPath: KeyPath<State, Value> & Sendable,
      send: @escaping (Value) -> Action
    ) -> Binding<Value> {
      Binding(
        get: { self[dynamicMember: keyPath] },
        set: { self.dispatch(send($0)) }
      )
    }
  }

  extension View {
    /// Store を Environment に入れます。子の View では `@Environment(Store<AppState, AppAction>.self)` で取り出せます。
    ///
    /// ```swift
    /// ContentView()
    ///   .store(store)
    ///
    /// struct ContentView: View {
    ///   @Environment(Store<AppState, AppAction>.self) private var store
    /// }
    /// ```
    public func store<State: Sendable, Action: Sendable>(_ store: Store<State, Action>) -> some View
    {
      environment(store)
    }
  }
#endif
