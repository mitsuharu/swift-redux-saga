import Redux
import Testing

private struct FormState: Sendable, Equatable {
  @BindableState var name = ""
  @BindableState var isOn = false
  var count = 0
}

private enum FormAction: Sendable, Equatable, BindableAction {
  case binding(BindingAction<FormState>)
  case increment

  var binding: BindingAction<FormState>? {
    if case .binding(let action) = self { action } else { nil }
  }
}

private let reducer = Reducer<FormState, FormAction> {
  Reducer.binding
  Reducer { state, action in
    if action == .increment { state.count += 1 }
  }
}

@Suite struct BindingActionTests {
  @Test func bindableStateIsReadAndWrittenLikeAPlainProperty() {
    var state = FormState()
    state.name = "a"
    #expect(state.name == "a")
    #expect(state.$name.wrappedValue == "a")
  }

  @Test func setActionWritesTheValueToTheProperty() {
    var state = FormState()
    BindingAction.set(\FormState.$name, "redux").apply(to: &state)
    BindingAction.set(\FormState.$isOn, true).apply(to: &state)
    #expect(state == FormState(name: "redux", isOn: true))
  }

  @Test func valueForReturnsTheValueOnlyForTheSameProperty() {
    let action = BindingAction.set(\FormState.$name, "x")
    #expect(action.value(for: \.$name) == "x")
    #expect(action.value(for: \.$isOn) == nil)
  }

  @Test func bindingActionsAreEqualWhenThePropertyAndTheValueAreEqual() {
    #expect(BindingAction.set(\FormState.$name, "a") == .set(\.$name, "a"))
    #expect(BindingAction.set(\FormState.$name, "a") != .set(\.$name, "b"))
    #expect(BindingAction.set(\FormState.$isOn, true) != .set(\.$name, "true"))
  }

  @Test func bindingReducerAppliesOnlyBindingActions() {
    var state = FormState()
    reducer.reduce(into: &state, action: .binding(.set(\.$name, "a")))
    reducer.reduce(into: &state, action: .increment)
    #expect(state == FormState(name: "a", count: 1))
  }
}
