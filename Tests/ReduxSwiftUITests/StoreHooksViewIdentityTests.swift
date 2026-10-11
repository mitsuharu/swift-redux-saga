#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import Observation
  import Redux
  import ReduxSwiftUI
  import SwiftUI
  import Testing

  private struct ItemsState: Sendable, Equatable {
    var items: [String: Int] = [:]
  }

  private enum ItemsAction: Sendable {
    case set(String, Int?)
  }

  private let reducer = Reducer<ItemsState, ItemsAction> { state, action in
    switch action {
    case .set(let id, let value): state.items[id] = value
    }
  }

  /// 親の View が表示する対象（ID）と Store。テストから書き換えて、親を再評価させる。
  @MainActor
  @Observable
  private final class Driver {
    var itemID: String
    var store: Store<ItemsState, ItemsAction>
    init(itemID: String, store: Store<ItemsState, ItemsAction>) {
      self.itemID = itemID
      self.store = store
    }
  }

  /// View の評価で読んだ値、セレクタが読んだ値、View から取り出した dispatch を記録する。
  @MainActor
  private final class Probe {
    var rendered: [Int?] = []
    var selected: [Int?] = []
    private(set) var dispatch: ((ItemsAction) -> Void)?

    func keep(dispatch: @escaping (ItemsAction) -> Void) {
      self.dispatch = dispatch
    }
  }

  /// 同じ View（identity と @State）のまま、親から ID と Store だけが変わる。
  private struct ParentView: View {
    let driver: Driver
    let probe: Probe

    var body: some View {
      ItemView(itemID: driver.itemID, probe: probe)
        .store(driver.store)
    }
  }

  private struct ItemView: View {
    let probe: Probe
    @SelectState<ItemsState, Int?> private var value: Int?
    @DispatchAction private var dispatch: (ItemsAction) -> Void

    init(itemID: String, probe: Probe) {
      self.probe = probe
      _value = SelectState { state in
        let value = state.items[itemID]
        probe.selected.append(value)
        return value
      }
    }

    var body: some View {
      let _ = probe.rendered.append(value)
      let _ = probe.keep(dispatch: dispatch)
      Text(value.map(String.init) ?? "-")
    }
  }

  @MainActor
  @Suite struct StoreHooksViewIdentityTests {
    @Test func changingTheTargetIDShowsTheNewTargetWithoutAStoreChangeAndKeepsFollowingIt() async {
      let store = Store(initialState: ItemsState(items: ["a": 1, "b": 2]), reducer: reducer)
      let driver = Driver(itemID: "a", store: store)
      let probe = Probe()
      let host = Host(ParentView(driver: driver, probe: probe))
      #expect(probe.rendered.last == 1)
      // 購読が始まっていることを確かめる。
      store.dispatch(.set("a", 10))
      #expect(await host.waitUntil { probe.rendered.last == 10 })

      // dispatch せずに、対象を b に変える。
      driver.itemID = "b"
      #expect(await host.waitUntil { probe.rendered.last == 2 })
      // 以後の変化も b を読む。
      store.dispatch(.set("b", 20))
      #expect(await host.waitUntil { probe.rendered.last == 20 })
      // a の変化では、表示が a の値にならない。
      store.dispatch(.set("a", 11))
      store.dispatch(.set("b", 21))
      #expect(await host.waitUntil { probe.rendered.last == 21 })
      #expect(!probe.rendered.contains(11))
    }

    @Test func replacingTheStoreReadsTheNewStoreAndIgnoresTheOldOne() async {
      let storeA = Store(initialState: ItemsState(items: ["a": 1]), reducer: reducer)
      let storeB = Store(initialState: ItemsState(items: ["a": 100]), reducer: reducer)
      let driver = Driver(itemID: "a", store: storeA)
      let probe = Probe()
      let host = Host(ParentView(driver: driver, probe: probe))
      storeA.dispatch(.set("a", 2))
      #expect(await host.waitUntil { probe.rendered.last == 2 })

      // dispatch せずに、Store を B に差し替える。B の今の値を読む。
      driver.store = storeB
      #expect(await host.waitUntil { probe.rendered.last == 100 })
      // A の変化の後に B を変え、B の変化が届いた時点で、A の変化は一度も読まれていない
      // （先に起きた A の変化の通知は、B の変化の通知より先に処理される）。
      storeA.dispatch(.set("a", 3))
      storeB.dispatch(.set("a", 101))
      #expect(await host.waitUntil { probe.rendered.last == 101 })
      #expect(!probe.selected.contains(3))
      #expect(!probe.rendered.contains(3))
    }

    @Test func afterReplacingTheStoreDispatchSendsToTheNewStoreOnly() async {
      let storeA = Store(initialState: ItemsState(items: ["a": 1]), reducer: reducer)
      let storeB = Store(initialState: ItemsState(items: ["a": 100]), reducer: reducer)
      let driver = Driver(itemID: "a", store: storeA)
      let probe = Probe()
      let host = Host(ParentView(driver: driver, probe: probe))
      probe.dispatch?(.set("a", 2))
      #expect(storeA.state.items["a"] == 2)

      driver.store = storeB
      #expect(await host.waitUntil { probe.rendered.last == 100 })
      probe.dispatch?(.set("a", 200))
      #expect(storeB.state.items["a"] == 200)
      #expect(storeA.state.items["a"] == 2)
    }

    @Test func anOptionalValueIsShownThroughNilValueAndNilAgain() async {
      let store = Store(initialState: ItemsState(), reducer: reducer)
      let driver = Driver(itemID: "a", store: store)
      let probe = Probe()
      let host = Host(ParentView(driver: driver, probe: probe))
      // 未接続ではなく、選択した値として nil を表示している。
      #expect(probe.rendered == [nil])
      store.dispatch(.set("a", 1))
      #expect(await host.waitUntil { probe.rendered.last == 1 })
      store.dispatch(.set("a", nil))
      #expect(await host.waitUntil { probe.rendered.last == .some(nil) })
      store.dispatch(.set("a", 2))
      #expect(await host.waitUntil { probe.rendered.last == 2 })
      #expect(probe.rendered == [nil, 1, nil, 2])
    }
  }
#endif
