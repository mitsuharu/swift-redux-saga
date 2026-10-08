#if canImport(UIKit)
  import Redux
  import ReduxUIKit
  import Testing
  import UIKit

  private enum Action: Sendable {
    case increment
  }

  private let reducer = Reducer<Int, Action> { state, _ in state += 1 }

  @MainActor
  @Suite struct UIKitHelperTests {
    @Test func actionDispatchesWhenPerformed() {
      let store = Store(initialState: 0, reducer: reducer)
      let button = UIButton(primaryAction: store.action(.increment, title: "+1"))
      button.sendActions(for: .primaryActionTriggered)
      #expect(store.state == 1)
      #expect(button.title(for: .normal) == "+1")
    }

    @Test func retainedTokenLivesAsLongAsItsOwner() {
      let store = Store(initialState: 0, reducer: reducer)
      var owner: NSObject? = NSObject()
      weak var weakToken: ObservationToken?
      do {
        let token = store.observe {
          $0.state
        } onChange: { _ in
        }
        token.retained(by: owner!)
        weakToken = token
      }
      #expect(weakToken != nil)
      owner = nil
      #expect(weakToken == nil)
    }
  }
#endif
