import Domain
import Foundation
import Observation
import Redux

/// ToDo 一覧画面の ViewModel（MVVM と併用する例）。
///
/// - 画面特有の状態（入力中の文字列）は ViewModel が持つ。Store に置くと State が画面の都合で大きくなるため。
/// - 複数の画面で使うデータは Store から読む。ViewModel の計算プロパティが Store を読むので、
///   Observation がそのまま連鎖し、Store が変わると View も更新される。
/// - View は ViewModel だけを見て、Store や Action を直接扱わない。
///
/// UI フレームワークに依存しないので、SwiftUI と UIKit の両方の画面で使える。
@MainActor
@Observable
public final class TodoListViewModel {
  private let store: Store<TodoFeature.State, TodoFeature.Action>

  /// 新しい ToDo の入力欄（画面特有の状態）。
  public var draft = ""

  public init(store: Store<TodoFeature.State, TodoFeature.Action>) {
    self.store = store
  }

  // MARK: - Store から読む値

  /// 表示する ToDo（検索語と設定で絞り込んだもの）。
  public var todos: [Todo] {
    TodoFeature.visibleTodos(store.state)
  }

  public var isLoading: Bool {
    store.isLoading
  }

  public var errorMessage: String? {
    store.errorMessage
  }

  /// 検索語。書き換えると Store に送り、Saga が入力の止まるのを待って反映する。
  public var query: String {
    get { store.query }
    set { store.dispatch(.binding(.set(\.$query, newValue))) }
  }

  /// 完了済みを表示するか（Store に置き、永続化する設定）。
  public var showsCompleted: Bool {
    get { store.preferences.showsCompleted }
    set { store.dispatch(.setShowsCompleted(newValue)) }
  }

  // MARK: - 画面特有の判断

  /// 追加ボタンを押せるか。
  public var canAdd: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - 操作

  /// 入力中の文字列で ToDo を追加し、入力欄を空にする。
  public func add() {
    guard canAdd else { return }
    store.dispatch(.add(title: draft))
    draft = ""
  }

  public func toggle(_ id: Todo.ID) {
    store.dispatch(.toggleTapped(id))
  }

  public func delete(_ id: Todo.ID) {
    store.dispatch(.deleteTapped(id))
  }

  public func refresh() {
    store.dispatch(.refresh)
  }

  public func dismissError() {
    store.dispatch(.errorDismissed)
  }
}
