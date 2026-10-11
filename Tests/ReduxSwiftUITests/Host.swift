#if canImport(SwiftUI) && (os(macOS) || os(iOS))
  import SwiftUI

  #if os(macOS)
    import AppKit
  #else
    import UIKit
  #endif

  /// SwiftUI の View を実際に表示して評価させる。
  @MainActor
  final class Host {
    #if os(macOS)
      private let view: NSHostingView<AnyView>
    #else
      private let controller: UIHostingController<AnyView>
      // UIKit は、ウインドウに入っていない View を描画しない（body も評価されない）ため、ウインドウに置く。
      private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    #endif

    init(_ content: some View) {
      #if os(macOS)
        view = NSHostingView(rootView: AnyView(content))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
      #else
        controller = UIHostingController(rootView: AnyView(content))
        window.rootViewController = controller
        window.isHidden = false
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
#endif
