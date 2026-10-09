extension Array where Element: Identifiable {
  /// ID の要素を読み書きします。
  ///
  /// 読むと、ID の要素がなければ `nil` を返します。`store.todos[id: id]` のように Store から読むと、
  /// 要素が削除された後も安全に読めます（添字 `\.todos[index]` のキーパスは、要素を削除すると範囲外になり、
  /// Store が変化を判定するときにプログラムが停止します）。
  ///
  /// 書くと、ID の要素を置き換えます。`nil` を書くと削除し、ID の要素がなければ末尾に追加します
  /// （`Dictionary` の添字と同じ）。
  ///
  /// ```swift
  /// // View
  /// Text(store.todos[id: id]?.title ?? "")
  /// // reducer
  /// state.todos[id: id]?.isDone.toggle()
  /// ```
  public subscript(id id: Element.ID) -> Element? {
    get {
      first { $0.id == id }
    }
    set {
      guard let index = firstIndex(where: { $0.id == id }) else {
        if let newValue { append(newValue) }
        return
      }
      if let newValue {
        self[index] = newValue
      } else {
        remove(at: index)
      }
    }
  }
}
