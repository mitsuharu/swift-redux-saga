#if canImport(Darwin)
  import os
#else
  import Synchronization
#endif

/// 値を排他制御付きで保持する入れ物。
///
/// Apple OS では `OSAllocatedUnfairLock`、それ以外では `Synchronization.Mutex` を使う。
/// `Mutex` に統一しないのは、Apple OS では iOS 18 / macOS 15 以降でしか使えず、
/// 本ライブラリの対応 OS（iOS 17 / macOS 14）を満たさないため。
package struct Locked<Value: Sendable>: Sendable {
  #if canImport(Darwin)
    private let lock: OSAllocatedUnfairLock<Value>
  #else
    private let storage: Storage
  #endif

  package init(_ value: Value) {
    #if canImport(Darwin)
      lock = OSAllocatedUnfairLock(initialState: value)
    #else
      storage = Storage(value)
    #endif
  }

  /// ロックを取って値を読み書きする。
  ///
  /// `body` の中で、ほかの `Locked` を取ったり、continuation を resume したり、
  /// 利用者のコードを呼んだりしない（デッドロックや再入を避けるため、ロックの外でまとめて行う）。
  package func withLock<Result: Sendable>(
    _ body: @Sendable (inout Value) -> Result
  ) -> Result {
    #if canImport(Darwin)
      lock.withLock(body)
    #else
      storage.mutex.withLock { body(&$0) }
    #endif
  }

  #if !canImport(Darwin)
    // Mutex は ~Copyable のため、struct のまま共有できるようクラスに包む。
    private final class Storage: Sendable {
      let mutex: Mutex<Value>
      init(_ value: Value) { mutex = Mutex(value) }
    }
  #endif
}
