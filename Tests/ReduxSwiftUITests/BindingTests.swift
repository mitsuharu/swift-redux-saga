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
