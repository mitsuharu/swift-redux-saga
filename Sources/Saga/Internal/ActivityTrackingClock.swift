/// 眠っている Saga を起こす直前に通知できる時計（テスト用の `TestClock` が準拠する）。
///
/// `delay` は、この時計なら眠る直前に Activity を減らし、起こされる直前（`onWake`）に増やす。
/// 起きた側ではなく起こす側で数えるのは、起こしてから実際に動き出すまでの間に
/// 「全員止まっている」と誤判定しないため（`Activity` を参照）。
/// それ以外の時計では、眠っている間も実行中として数える（テスト支援の `settle()` は実際に待つことになる）。
package protocol ActivityTrackingClock: Sendable {
  /// `duration` だけ眠る。`onWake` は、戻るか投げる前に必ずちょうど 1 回呼ぶこと。
  func sleep(for duration: Duration, onWake: @escaping @Sendable () -> Void) async throws
}
