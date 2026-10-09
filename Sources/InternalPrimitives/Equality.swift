/// 値が `Equatable` なら等しいかを返し、そうでなければ `false`（変わったとみなす）を返す。
///
/// State やスナップショットの型が `Equatable` かどうかは、利用者の型によって決まる。
/// 型で分けた多重定義にしないのは、ジェネリックな文脈（`Store<State, Action>` など）からは
/// `Equatable` の版を選べないため、実行時に判定する。
package func isEqualIfEquatable<Value>(_ lhs: Value, _ rhs: Value) -> Bool {
  guard let lhs = lhs as? any Equatable else { return false }
  return lhs.isEqual(to: rhs)
}

extension Equatable {
  fileprivate func isEqual(to other: Any) -> Bool {
    guard let other = other as? Self else { return false }
    return self == other
  }
}
