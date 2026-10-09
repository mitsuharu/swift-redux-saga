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

  extension Store {
    /// Optional の値（ID で読んだ一覧の要素のプロパティなど）から `Binding` を作ります。
    ///
    /// 値が `nil`（要素が削除された後など）のときは `defaultValue` を返します。一覧の要素を編集する場合は、
    /// 添字（`\.todos[index]`）ではなく ID（`\.todos[id: id]` や `EntityState` の `\.todos.entities[id]`）で
    /// 読んでください。添字は要素を削除すると範囲外になり、プログラムが停止します。
    ///
    /// ```swift
    /// TextField("Title", text: store.binding(\.todos[id: id]?.title, default: "") {
    ///   .rename(id: id, title: $0)
    /// })
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: State の中の Optional の値。
    ///   - defaultValue: 値が `nil` のときに返す値。
    ///   - send: 新しい値から dispatch する Action を作る関数。
    public func binding<Value: Equatable>(
      _ keyPath: KeyPath<State, Value?> & Sendable,
      default defaultValue: Value,
      send: @escaping (Value) -> Action
    ) -> Binding<Value> {
      Binding(
        get: { self[dynamicMember: keyPath] ?? defaultValue },
        set: { self.dispatch(send($0)) }
      )
    }
  }

  extension Store where Action: BindableAction, Action.State == State {
    /// `BindableState` を付けたプロパティの `Binding` を作ります。
    ///
    /// 値を変えると `BindingAction` を包んだ Action（`.binding(.set(...))`）を dispatch します。
    /// 入力欄ごとに Action を用意する必要はありません。
    ///
    /// ```swift
    /// TextField("New ToDo", text: store.binding(\.$draft))
    /// Toggle("Notifications", isOn: store.binding(\.$isNotificationOn))
    /// ```
    public func binding<Value: Equatable & Sendable>(
      _ keyPath: WritableKeyPath<State, BindableState<Value>> & Sendable
    ) -> Binding<Value> {
      Binding(
        get: { self[dynamicMember: keyPath].wrappedValue },
        set: { self.dispatch(.binding(.set(keyPath, $0))) }
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
