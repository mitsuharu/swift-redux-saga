// watchOS の UIKit には UIAction や UIViewController がないため対象外にする。
#if canImport(UIKit) && !os(watchOS)
  import ObjectiveC
  import Redux
  import UIKit

  extension ObservationToken {
    /// `owner` が解放されるまで購読を続けます。
    ///
    /// View Controller などにトークンのプロパティを用意せずに、寿命を結びつけたい場合に使います。
    ///
    /// ```swift
    /// override func viewDidLoad() {
    ///   super.viewDidLoad()
    ///   store.observe { $0.count } onChange: { [weak self] count in
    ///     self?.label.text = "\(count)"
    ///   }
    ///   .retained(by: self)
    /// }
    /// ```
    ///
    /// iOS 26 以降（または `UIObservationTrackingEnabled` を有効にした iOS 18 以降）では、
    /// `viewWillLayoutSubviews()` や `updateProperties()` で `store.count` を読むだけで UIKit が自動で追跡するため、
    /// このメソッドは不要です。
    public func retained(by owner: AnyObject) {
      // キーにトークン自身のアドレスを使うのは、グローバルな可変のキーを持たずに、トークンごとに一意にするため。
      let key = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
      objc_setAssociatedObject(owner, key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  extension Store {
    /// 実行すると Action を dispatch する `UIAction` を作ります。
    ///
    /// ```swift
    /// let button = UIButton(primaryAction: store.action(.increment, title: "+1"))
    /// ```
    ///
    /// `UIAction` は Store を弱参照します。
    public func action(
      _ action: Action, title: String = "", image: UIImage? = nil
    ) -> UIAction {
      UIAction(title: title, image: image) { [weak self] _ in
        self?.dispatch(action)
      }
    }
  }
#endif
