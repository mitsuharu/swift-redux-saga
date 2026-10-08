#if canImport(os)
  import os
#endif

/// dispatch された Action（と、必要なら適用後の State）をログに出すミドルウェア。
///
/// 既定ではデバッグビルドでだけ出力し、リリースビルドでは何もしません。
/// Apple OS では `os.Logger` の `debug` レベルで出力するので、Xcode のコンソールと Console.app で見られます。
/// それ以外の OS では標準出力に出力します。
///
/// ```swift
/// let store = Store(initialState: AppState(), reducer: appReducer, middleware: [
///   LoggingMiddleware(),
///   sagaMiddleware,
/// ])
/// ```
///
/// 値は既定で `.private` として出力します。Xcode から実行しているときのコンソールには表示され、
/// 端末のログでは伏せられます（Action や State には個人情報が含まれ得るため）。
@MainActor
public struct LoggingMiddleware<State: Sendable, Action: Sendable>: Middleware {
  /// ログに出す値の扱い。
  public enum Privacy: Sendable {
    /// 端末のログでは伏せる（Xcode のコンソールには表示される）。
    case `private`
    /// 常に表示する。
    case `public`
  }

  private let isEnabled: Bool
  private let logsState: Bool
  private let privacy: Privacy
  private let filter: @Sendable (Action) -> Bool
  #if canImport(os)
    private let logger: Logger
  #endif

  /// ミドルウェアを作ります。
  ///
  /// - Parameters:
  ///   - isEnabled: ログを出すかどうか。省略するとデバッグビルドでだけ出します。
  ///   - logsState: Action を適用した後の State も出すかどうか。
  ///   - privacy: ログに出す値の扱い。
  ///   - subsystem: `os.Logger` の subsystem。
  ///   - category: `os.Logger` の category。
  ///   - filter: ログに出す Action を選ぶ関数。
  public init(
    isEnabled: Bool? = nil,
    logsState: Bool = false,
    privacy: Privacy = .private,
    subsystem: String = "swift-redux-saga",
    category: String = "Redux",
    filter: @escaping @Sendable (Action) -> Bool = { _ in true }
  ) {
    #if DEBUG
      self.isEnabled = isEnabled ?? true
    #else
      self.isEnabled = isEnabled ?? false
    #endif
    self.logsState = logsState
    self.privacy = privacy
    self.filter = filter
    #if canImport(os)
      self.logger = Logger(subsystem: subsystem, category: category)
    #endif
  }

  public func handle(
    _ action: Action, store: MiddlewareAPI<State, Action>, next: (Action) -> Void
  ) {
    guard isEnabled, filter(action) else {
      next(action)
      return
    }
    log("action", action)
    next(action)
    if logsState {
      log("state", store.state)
    }
  }

  private func log(_ label: String, _ value: Any) {
    let description = String(describing: value)
    #if canImport(os)
      // privacy に実行時の値を渡さず分岐するのは、OSLogMessage の privacy にはリテラルを渡す必要があるため。
      switch privacy {
      case .private: logger.debug("\(label, privacy: .public): \(description, privacy: .private)")
      case .public: logger.debug("\(label, privacy: .public): \(description, privacy: .public)")
      }
    #else
      print("[Redux] \(label): \(description)")
    #endif
  }
}
