#if canImport(SwiftUI)
  import InternalPrimitives
  import Observation
  import Redux
  import ReduxSwiftUI
  import SwiftUI
  import Testing

  private struct FormState: Sendable, Equatable {
    var name = ""
    var count = 0
  }

  private enum FormAction: Sendable, Equatable {
    case rename(String)
    case increment
  }

  private let reducer = Reducer<FormState, FormAction> { state, action in
    switch action {
    case .rename(let name): state.name = name
    case .increment: state.count += 1
    }
  }

  private struct Item: Sendable, Equatable, Identifiable {
    var id: Int
    var title: String
  }

  private enum ListAction: Sendable, Equatable {
    case rename(id: Int, title: String)
    case remove(id: Int)
  }

  private let listReducer = Reducer<[Item], ListAction> { items, action in
    switch action {
    case .rename(let id, let title): items[id: id]?.title = title
    case .remove(let id): items[id: id] = nil
    }
  }

  @MainActor
  @Suite struct OptionalBindingTests {
    @Test func bindingToAnElementReadByIDReadsAndWrites() {
      let store = Store(initialState: [Item(id: 1, title: "a")], reducer: listReducer)
      let title = store.binding(\.[id: 1]?.title, default: "") { .rename(id: 1, title: $0) }
      #expect(title.wrappedValue == "a")
      title.wrappedValue = "b"
      #expect(store.state == [Item(id: 1, title: "b")])
    }

    @Test func bindingToARemovedElementReturnsTheDefaultValue() {
      let store = Store(
        initialState: [Item(id: 1, title: "a"), Item(id: 2, title: "b")], reducer: listReducer)
      let title = store.binding(\.[id: 2]?.title, default: "") { .rename(id: 2, title: $0) }
      #expect(title.wrappedValue == "b")
      store.dispatch(.remove(id: 2))
      #expect(title.wrappedValue == "")
    }
  }

  @MainActor
  @Suite struct BindingTests {
    @Test func bindingReadsTheCurrentValue() {
      let store = Store(initialState: FormState(name: "a"), reducer: reducer)
      let name = store.binding(\.name, send: { .rename($0) })
      #expect(name.wrappedValue == "a")
      store.dispatch(.rename("b"))
      #expect(name.wrappedValue == "b")
    }

    @Test func settingTheBindingDispatchesTheAction() {
      let store = Store(initialState: FormState(), reducer: reducer)
      let name = store.binding(\.name, send: { .rename($0) })
      name.wrappedValue = "redux"
      #expect(store.name == "redux")
    }

    @Test func readingTheBindingTracksOnlyThatProperty() {
      let store = Store(initialState: FormState(), reducer: reducer)
      let name = store.binding(\.name, send: { .rename($0) })
      let notified = Locked(false)
      withObservationTracking {
        _ = name.wrappedValue
      } onChange: {
        notified.withLock { $0 = true }
      }
      store.dispatch(.increment)
      #expect(!notified.withLock { $0 })
      store.dispatch(.rename("x"))
      #expect(notified.withLock { $0 })
    }
  }
#endif

#if canImport(SwiftUI)
  import ReduxSwiftUI

  private struct SettingsState: Sendable, Equatable {
    @BindableState var name = ""
    var other = 0
  }

  private enum SettingsAction: Sendable, BindableAction {
    case binding(BindingAction<SettingsState>)
    case touch

    var binding: BindingAction<SettingsState>? {
      if case .binding(let action) = self { action } else { nil }
    }
  }

  @MainActor
  @Suite struct BindableStateBindingTests {
    @Test func bindingToABindableStateDispatchesABindingAction() {
      let store = Store(
        initialState: SettingsState(),
        reducer: Reducer<SettingsState, SettingsAction> {
          Reducer.binding
          Reducer { state, action in
            if case .touch = action { state.other += 1 }
          }
        }
      )
      let name = store.binding(\.$name)
      name.wrappedValue = "redux"
      #expect(store.name == "redux")
      #expect(name.wrappedValue == "redux")
    }
  }
#endif
