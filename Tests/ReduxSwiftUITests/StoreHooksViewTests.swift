#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import Redux
  import ReduxSwiftUI
  import SwiftUI
  import Testing

  #if os(macOS)
    import AppKit
  #else
    import UIKit
  #endif

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

  private struct CounterView: View {
    let probe: Probe
    @SelectState<CounterState, Int> private var count: Int
    @DispatchAction private var dispatch: (CounterAction) -> Void

    init(probe: Probe) {
      self.probe = probe
      _count = SelectState { state in
        probe.selections += 1
        return state.count
      }
    }

    var body: some View {
      let _ = probe.rendered.append(count)
      Button("\(count)") { dispatch(.increment) }
    }
  }

  /// SwiftUI の View を実際に表示して評価させる。
  @MainActor
  private final class Host {
    #if os(macOS)
      private let view: NSHostingView<AnyView>
    #else
      private let controller: UIHostingController<AnyView>
    #endif

    init(_ content: some View) {
      #if os(macOS)
        view = NSHostingView(rootView: AnyView(content))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
      #else
        controller = UIHostingController(rootView: AnyView(content))
        controller.view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
      #endif
      layout()
    }

    func layout() {
      #if os(macOS)
        view.layoutSubtreeIfNeeded()
      #else
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
      #endif
    }

    func replace(with content: some View) {
      #if os(macOS)
        view.rootView = AnyView(content)
      #else
        controller.rootView = AnyView(content)
      #endif
      layout()
    }

    /// 条件を満たすまで再描画を促す。上限を超えたら false を返す（実時間は上限の判定にだけ使う）。
    func waitUntil(_ condition: () -> Bool) async -> Bool {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
        layout()
      }
      return true
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

    @Test func removingTheViewStopsReadingTheStore() async {
      let store = Store(initialState: CounterState(), reducer: reducer)
      let probe = Probe()
      let host = Host(CounterView(probe: probe).store(store))
      // 購読が始まっていることを確かめてから外す。
      store.dispatch(.increment)
      #expect(await host.waitUntil { probe.rendered.last == 1 })
      host.replace(with: EmptyView())
      let selectionsAfterRemoval = probe.selections
      store.dispatch(.increment)
      // Store の変化の通知が一巡するのを待つ（後から登録した購読が届いた時点で、先の購読の処理も終わっている）。
      var latest = store.values { $0.count }.makeAsyncIterator()
      while await latest.next() != 2 {}
      host.layout()
      #expect(probe.selections == selectionsAfterRemoval)
    }
  }
#endif
