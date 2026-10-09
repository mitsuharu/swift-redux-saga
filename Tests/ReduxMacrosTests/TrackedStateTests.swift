import InternalPrimitives
import Observation
import Redux
import ReduxMacros
import Testing

@TrackedState
struct Address: Sendable, Equatable {
  var city: String = ""
  var zip: String = ""
}

@TrackedState
struct Profile: Sendable, Equatable {
  var name: String = ""
  var age: Int = 0
  var address: Address = Address()
  var tags: [String] = []

  /// 計算プロパティは、中で読んだ保存プロパティが追跡される。
  var isAdult: Bool { age >= 20 }
}

/// 追跡の仕組みを入れられないプロパティ（let と プロパティラッパー）を持つ型。
@TrackedState
struct Form: Sendable, Equatable {
  let id: Int
  @BindableState var draft = ""
  var note: String = ""
}

struct TrackedAppState: Sendable, Equatable {
  var form = Form(id: 0)
  var profile = Profile()
  var count = 0
}

enum TrackedAppAction: Sendable {
  case rename(String)
  case birthday
  case move(String)
  case increment
  case replaceProfile(Profile)
  case editDraft(String)
  case replaceForm(Form)
}

let trackedReducer = Reducer<TrackedAppState, TrackedAppAction> { state, action in
  switch action {
  case .rename(let name): state.profile.name = name
  case .birthday: state.profile.age += 1
  case .move(let city): state.profile.address.city = city
  case .increment: state.count += 1
  case .replaceProfile(let profile): state.profile = profile
  case .editDraft(let draft): state.form.draft = draft
  case .replaceForm(let form): state.form = form
  }
}

@MainActor
@Suite struct TrackedStateTests {
  /// `read` の中で読んだ値について、各 Action の dispatch で通知されたかどうかを返す。
  private func notifications(
    reading read: @escaping @MainActor (Store<TrackedAppState, TrackedAppAction>) -> Void,
    actions: [TrackedAppAction]
  ) -> [Bool] {
    let store = Store(initialState: TrackedAppState(), reducer: trackedReducer)
    return actions.map { action in
      let notified = Locked(false)
      withObservationTracking {
        read(store)
      } onChange: {
        notified.withLock { $0 = true }
      }
      store.dispatch(action)
      return notified.withLock { $0 }
    }
  }

  @Test func readingANestedPropertyNotifiesOnlyWhenThatPropertyChanges() {
    let result = notifications(
      reading: { _ = $0.profile.name },
      actions: [.birthday, .move("Tokyo"), .increment, .rename("Ada")])
    #expect(result == [false, false, false, true])
  }

  @Test func readingADeeplyNestedPropertyIsTrackedThroughNestedTrackedStates() {
    let result = notifications(
      reading: { _ = $0.profile.address.city },
      actions: [.rename("Ada"), .move("Tokyo"), .move("Tokyo")])
    #expect(result == [false, true, false])
  }

  @Test func readingAComputedPropertyTracksTheStoredPropertiesItReads() {
    let result = notifications(
      reading: { _ = $0.profile.isAdult },
      actions: [.rename("Ada"), .birthday])
    #expect(result == [false, true])
  }

  @Test func replacingTheWholeNestedValueNotifiesReadPropertiesThatChanged() {
    var other = Profile()
    other.name = "Grace"
    let result = notifications(
      reading: { _ = $0.profile.name },
      actions: [.replaceProfile(Profile()), .replaceProfile(other)])
    #expect(result == [false, true])
  }

  @Test func untrackablePropertiesAreNotifiedThroughTheWholeValue() {
    let result = notifications(
      reading: { _ = $0.form.draft },
      actions: [.birthday, .editDraft("a"), .replaceForm(Form(id: 1, draft: "a"))])
    #expect(result == [false, true, true])
    #expect(Form._$hasUntrackedProperties)
    #expect(!Profile._$hasUntrackedProperties)
  }

  @Test func readingTheWholeStateStillTracksEverything() {
    let result = notifications(reading: { _ = $0.state.profile.name }, actions: [.birthday])
    #expect(result == [true])
  }

  @Test func trackedStateValuesKeepValueSemanticsAndEquality() {
    var a = Profile()
    a.name = "x"
    let b = a
    a.age = 3
    #expect(b.age == 0)
    var c = Profile()
    c.name = "x"
    #expect(b == c)
    let store = Store(initialState: TrackedAppState(), reducer: trackedReducer)
    #expect(store.profile == Profile())  // 読み取り元の情報は比較に影響しない
  }

  @Test func memberwiseInitializerStillWorks() {
    let profile = Profile(name: "Ada", age: 36)
    #expect(profile.name == "Ada")
    #expect(profile.address == Address())
  }
}

@MainActor
@Suite struct TrackedStateMemoryTests {
  @Test func aTrackedValueKeptAfterReadingDoesNotKeepTheStoreAlive() {
    weak var weakStore: Store<TrackedAppState, TrackedAppAction>?
    var kept: Profile?
    do {
      let store = Store(initialState: TrackedAppState(), reducer: trackedReducer)
      weakStore = store
      kept = store.profile  // 読み取り元（Store への参照）を持った値を持ち出す
    }
    #expect(weakStore == nil)
    #expect(kept?.name == "")  // Store の解放後に読んでも落ちない
  }
}
