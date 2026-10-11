#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import Redux
  import ReduxSwiftUI
  import SwiftUI
  import Testing

  private struct CounterState: Sendable, Equatable {
    var count = 0
    var other = 0
  }

  private enum CounterAction: Sendable {
    case increment
    case touchOther
  }

  private let reducer = Reducer<CounterState, CounterAction> { state, action in
    switch action {
    case .increment: state.count += 1
    case .touchOther: state.other += 1
    }
  }

  /// View の評価で読んだ値と、セレクタが呼ばれた回数を記録する。
  @MainActor
  private final class Probe {
    var rendered: [Int] = []
    var selections = 0
  }

  /// セレクタが保持されている間だけ生きているもの。解放されたかを weak 参照で確かめる。
  private final class Marker {}

  private struct CounterView: View {
    let probe: Probe
    @SelectState<CounterState, Int> private var count: Int
    @DispatchAction private var dispatch: (CounterAction) -> Void

    init(probe: Probe, marker: Marker = Marker()) {
      self.probe = probe
      _count = SelectState { state in
        _ = marker
        probe.selections += 1
        return state.count
      }
    }

    var body: some View {
      let _ = probe.rendered.append(count)
      Button("\(count)") { dispatch(.increment) }
    }
  }

  @MainActor
  @Suite struct StoreHooksViewTests {
    @Test func aViewShowsTheSelectedValueAndFollowsItsChanges() async {
      let store = Store(initialState: CounterState(), reducer: reducer)
      let probe = Probe()
      let host = Host(CounterView(probe: probe).store(store))
      #expect(probe.rendered.last == 0)
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 1 })
    }

    @Test func aViewIsNotRenderedAgainForChangesItDoesNotRead() async {
      let store = Store(initialState: CounterState(), reducer: reducer)
      let probe = Probe()
      let host = Host(CounterView(probe: probe).store(store))
      // 購読が始まっていることを、読んでいる値の変化が届くことで確かめる。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 1 })
      let (renderedBefore, selectionsBefore) = (probe.rendered.count, probe.selections)
      // 読んでいない値の変化。セレクタは呼ばれるが、結果が変わらないので再描画されない。
      store.dispatch(.touchOther)
      #expect(await host.waitUntil { probe.selections > selectionsBefore })
      host.layout()
      #expect(probe.rendered.count == renderedBefore)
      // 読んでいる値の変化では再描画される。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 2 })
    }

    @Test func removingTheViewReleasesItsSubscriptionAndStopsReadingTheStore() async {
      let store = Store(initialState: CounterState(), reducer: reducer)
      let probe = Probe()
      weak var weakMarker: Marker?
      let host: Host
      do {
        let marker = Marker()
        weakMarker = marker
        host = Host(CounterView(probe: probe, marker: marker).store(store))
      }
      // 購読が始まっていることを確かめてから外す。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 1 })
      host.replace(with: EmptyView())
      // セレクタを保持していた値の持ち主（読んだ値と購読）が解放される。購読は持ち主と一緒に解放されるので、
      // これ以降の変化は届かない。
      #expect(await host.waitUntil { weakMarker == nil })
      let selectionsAfterRemoval = probe.selections
      store.dispatch(.increment)
      host.layout()
      #expect(probe.selections == selectionsAfterRemoval)
    }
  }
#endif
