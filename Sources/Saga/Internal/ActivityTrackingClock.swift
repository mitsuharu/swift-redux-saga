/// 眠っている Saga を起こす直前に通知できる時計（テスト用の `TestClock` が準拠する）。
///
/// `delay` は、この時計なら眠る登録をした直後（`onSleep`）に Activity を減らし、起こされる直前（`onWake`）に増やす。
/// 起きた側ではなく起こす側で数えるのは、起こしてから実際に動き出すまでの間に
/// 「全員止まっている」と誤判定しないため（`Activity` を参照）。
/// 登録する前に減らさないのは、減らしてから登録するまでの間に「全員止まっている」と判定され、
/// テストが時計を進め終えた後に登録されて、起こされない眠りが残るため。
/// それ以外の時計（実時間）では、眠った Saga が起きた後に自分で数え直す。
package protocol ActivityTrackingClock: Sendable {
  /// `duration` だけ眠る。
  ///
  /// 眠る登録をしたら `onSleep` を呼び、その眠りから起こすとき（時間が来た、キャンセルされた）に `onWake` を呼ぶ。
  /// 登録せずに戻る場合（すでに時間が来ている、キャンセル済み）は、どちらも呼ばない。
  func sleep(
    for duration: Duration,
    onSleep: @escaping @Sendable () -> Void,
    onWake: @escaping @Sendable () -> Void
  ) async throws
}
