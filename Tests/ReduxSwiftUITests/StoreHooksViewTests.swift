#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import InternalPrimitives
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

  /// メモ化したセレクタ（createSelector）を、View の評価のたびに作り直さずに渡す。
  private struct DoubledView: View {
    let probe: Probe
    @SelectState<CounterState, Int> private var doubled: Int

    init(selector: Redux.Selector<CounterState, Int>, probe: Probe) {
      self.probe = probe
      _doubled = SelectState { state in
        probe.selections += 1
        return selector(state)
      }
    }

    var body: some View {
      let _ = probe.rendered.append(doubled)
      Text("\(doubled)")
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

    @Test func aMemoizedSelectorDoesNotRecomputeForChangesToOtherInputs() async {
      let store = Store(initialState: CounterState(), reducer: reducer)
      let probe = Probe()
      let resultCalls = Locked(0)
      let doubled = createSelector(\CounterState.count) { count in
        resultCalls.withLock { $0 += 1 }
        return count * 2
      }
      let host = Host(DoubledView(selector: doubled, probe: probe).store(store))
      // 購読が始まっていることを確かめる。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 2 })
      let callsBefore = resultCalls.withLock { $0 }
      let renderedBefore = probe.rendered.count
      // 入力（count）以外の変化。@SelectState のセレクタは呼ばれるが、結果の計算は前回の結果で済む。
      for _ in 0..<3 {
        let selectionsBefore = probe.selections
        store.dispatch(.touchOther)
        #expect(await host.waitUntil { probe.selections > selectionsBefore })
      }
      host.layout()
      #expect(resultCalls.withLock { $0 } == callsBefore)
      #expect(probe.rendered.count == renderedBefore)
      // 入力が変わったときは計算し直す。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 4 })
      #expect(resultCalls.withLock { $0 } == callsBefore + 1)
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
