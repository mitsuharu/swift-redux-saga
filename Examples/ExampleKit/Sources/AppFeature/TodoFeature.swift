import Domain
import Foundation
import Redux
import ReduxMacros
import Saga

/// ToDo の State・Action・reducer。
///
/// Store に置くのは、複数の画面で使うデータ（ToDo の一覧、読み込み中、エラー）と、Saga が関わる処理（検索）、
/// 永続化する設定。入力中の文字列のような画面特有の状態は ViewModel（`TodoListViewModel`）に持たせる。
///
/// `@Slice` が Slice への準拠を加え、`Action` に `@ActionCases` を付ける（case ごとのプロパティが生成される）。
@Slice
public enum TodoFeature {
  public struct State: Sendable, Equatable {
    public var todos = EntityState<Todo.ID, Todo>()
    public var isLoading = false
    /// 永続化する設定。
    public var preferences = Preferences()
    /// 検索欄に入力中の文字列。入力欄から直接書き換える（BindingAction）。
    @BindableState public var query = ""
    /// 入力が止まってから反映した検索語（Saga の debounce で更新する）。
    public var appliedQuery = ""
    public var errorMessage: String?

    public init() {}
  }

  /// 永続化する設定（`ReduxPersistence` で保存する）。
  public struct Preferences: Sendable, Equatable, Codable {
    /// 完了済みの ToDo を表示するか。
    public var showsCompleted = true

    public init(showsCompleted: Bool = true) {
      self.showsCompleted = showsCompleted
    }
  }

  public enum Action: Sendable, Equatable, BindableAction {
    /// 入力欄（query）の書き換え。`store.binding(\.$query)` が送る。
    case binding(BindingAction<State>)

    // View から送る Action
    /// 一覧を読み込み直す（引っぱって更新など）。起動時は Saga が自分で送る。
    case refresh
    /// タイトルから ToDo を追加する（入力中の文字列は ViewModel が持つ）。
    case add(title: String)
    case toggleTapped(Todo.ID)
    case deleteTapped(Todo.ID)
    case errorDismissed
    case setShowsCompleted(Bool)

    // Saga が送る Action
    case queryApplied(String)
    case loaded([Todo])
    case added(Todo)
    case updated(Todo)
    case deleted(Todo.ID)
    case failed(String)
  }

  public static let initialState = State()

  static let adapter = EntityAdapter<Todo.ID, Todo>(sortedBy: { $0.createdAt < $1.createdAt })

  public static func reduce(into state: inout State, action: Action) {
    switch action {
    case .refresh:
      state.isLoading = true
    case .binding(let binding):
      binding.apply(to: &state)
    case .add, .toggleTapped, .deleteTapped:
      break
    case .setShowsCompleted(let showsCompleted):
      state.preferences.showsCompleted = showsCompleted
    case .queryApplied(let query):
      state.appliedQuery = query
    case .errorDismissed:
      state.errorMessage = nil
    case .loaded(let todos):
      state.isLoading = false
      adapter.setAll(todos, in: &state.todos)
    case .added(let todo):
      adapter.setOne(todo, in: &state.todos)
    case .updated(let todo):
      adapter.setOne(todo, in: &state.todos)
    case .deleted(let id):
      adapter.removeOne(id, from: &state.todos)
    case .failed(let message):
      state.isLoading = false
      state.errorMessage = message
    }
  }

  /// 検索語と設定で絞り込んだ ToDo。入力が変わらない限り再計算しない。
  public static let visibleTodos = createSelector(
    \State.todos, \.appliedQuery, \.preferences.showsCompleted
  ) { todos, query, showsCompleted in
    adapter.all(in: todos).filter { todo in
      (showsCompleted || !todo.isDone)
        && (query.isEmpty || todo.title.localizedCaseInsensitiveContains(query))
    }
  }
}

/// ToDo 画面の Saga。View から届いた Action を受けて UseCase を呼び、結果を Action で返す。
///
/// UseCase（Domain）は本ライブラリに依存しない。Saga は両者をつなぐ薄い層。
public struct TodoSagas: Sendable {
  private let useCase: TodoUseCase

  public init(useCase: TodoUseCase) {
    self.useCase = useCase
  }

  public var root: Saga<TodoFeature.State, TodoFeature.Action> {
    Saga("todo") { ctx in
      ctx.takeLatest(.action(.refresh)) { ctx, _ in
        await perform(ctx) { .loaded(try await ctx.call(useCase.load)) }
      }
      // 二重送信を防ぐため、追加の処理中に届いた addTapped は無視する。
      ctx.takeLeading(.case(\.add)) { ctx, title in
        await perform(ctx) {
          guard let todo = try await ctx.call(useCase.add, title) else { return nil }
          return .added(todo)
        }
      }
      // 入力が止まってから検索語を反映する。
      ctx.debounce(.milliseconds(300), .binding(\.$query)) { ctx, query in
        await ctx.put(.queryApplied(query))
      }
      ctx.takeEvery(.case(\.toggleTapped)) { ctx, id in
        guard let todo = await ctx.select({ $0.todos.entities[id] }) else { return }
        await perform(ctx) { .updated(try await ctx.call(useCase.toggle, todo)) }
      }
      ctx.takeEvery(.case(\.deleteTapped)) { ctx, id in
        await perform(ctx) {
          try await ctx.call(useCase.delete, id)
          return .deleted(id)
        }
      }

      // 起動時の読み込みは、View から送らずにルート Saga で始める。
      // run の直後に外から dispatch すると、Saga が待ち始める前に届いて取りこぼすことがあるため
      // （設計書 7 章「起動直後の Action」）。ヘルパーは呼び出した時点で購読を始めているので、ここで put すれば届く。
      await ctx.put(.refresh)
    }
  }

  /// 処理の結果を put し、失敗したらエラーの Action を put する。
  private func perform(
    _ ctx: SagaContext<TodoFeature.State, TodoFeature.Action>,
    _ operation: () async throws -> TodoFeature.Action?
  ) async {
    do {
      if let action = try await operation() { await ctx.put(action) }
    } catch is CancellationError {
    } catch {
      await ctx.put(.failed(error.localizedDescription))
    }
  }
}
