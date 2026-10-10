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
    /// 一覧の世代。ログアウトで一覧を消すたびに変わる（`RootFeature` が進める）。
    ///
    /// Saga は処理を始めた時点の世代を結果の Action に含め、reducer は今の世代と違う結果を捨てる。
    /// ログアウトで Saga をキャンセルしても、通信が終わってから put するまでの間にログアウトされると、
    /// 前のセッションの結果が届き得るため。
    public var generation = 0

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

    // Saga が送る Action（結果には、処理を始めた時点の世代を含める）
    case queryApplied(String)
    case loaded([Todo], generation: Int)
    case added(Todo, generation: Int)
    case updated(Todo, generation: Int)
    case deleted(Todo.ID, generation: Int)
    case failed(String, generation: Int)

    /// 一覧を読み書きする Action か（Saga が届いた順に 1 件ずつ処理する）。
    var readsOrWritesTodos: Bool {
      switch self {
      case .refresh, .add, .toggleTapped, .deleteTapped: true
      default: false
      }
    }

    /// Saga の処理の結果なら、処理を始めた時点の世代。
    var resultGeneration: Int? {
      switch self {
      case .loaded(_, let generation), .added(_, let generation), .updated(_, let generation),
        .deleted(_, let generation), .failed(_, let generation):
        generation
      default:
        nil
      }
    }
  }

  public static let initialState = State()

  static let adapter = EntityAdapter<Todo.ID, Todo>(sortedBy: { $0.createdAt < $1.createdAt })

  public static func reduce(into state: inout State, action: Action) {
    // 前の世代（ログアウト前のセッション）の結果は捨てる。
    if let generation = action.resultGeneration, generation != state.generation {
      return
    }
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
    case .loaded(let todos, _):
      state.isLoading = false
      adapter.setAll(todos, in: &state.todos)
    case .added(let todo, _):
      adapter.setOne(todo, in: &state.todos)
    case .updated(let todo, _):
      adapter.setOne(todo, in: &state.todos)
    case .deleted(let id, _):
      adapter.removeOne(id, from: &state.todos)
    case .failed(let message, _):
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
      // 読み込み・追加・完了の切り替え・削除は、届いた順に 1 件ずつ行う。
      // - takeLeading にしないのは、保存中に追加した ToDo を捨ててしまうため（入力欄はもう空になっている）。
      // - takeEvery にしないのは、同じ ToDo を続けて切り替えると、どちらも保存前の値を読んで反転し、
      //   1 回分の変更になるため。1 件ずつなら、2 回目は 1 回目の保存後の値を読む。
      // - 読み込みも同じ順番に並べるのは、編集と並行すると「読み込み開始 → 削除 → 古い一覧が到着」の順で、
      //   削除した ToDo が一覧に戻るため（takeLatest が整理するのは読み込み同士だけ）。
      let requests = ctx.actionChannel(.filter(\.readsOrWritesTodos))
      ctx.fork("todo.requests") { ctx in
        for try await request in requests {
          await handle(ctx, request)
        }
      }
      // 入力が止まってから検索語を反映する。
      ctx.debounce(.milliseconds(300), .binding(\.$query)) { ctx, query in
        await ctx.put(.queryApplied(query))
      }

      // 起動時の読み込みは、View の表示とは関係なく始めたいので、View から送らずにルート Saga で始める。
      await ctx.put(.refresh)
    }
  }

  /// 一覧の読み込みか編集を 1 件行い、結果を put する。
  private func handle(
    _ ctx: SagaContext<TodoFeature.State, TodoFeature.Action>, _ request: TodoFeature.Action
  ) async {
    switch request {
    case .refresh:
      await perform(ctx) { .loaded(try await ctx.call(useCase.load), generation: $0) }
    case .add(let title):
      await perform(ctx) { generation in
        guard let todo = try await ctx.call(useCase.add, title) else { return nil }
        return .added(todo, generation: generation)
      }
    case .toggleTapped(let id):
      // 保存する直前の値を読む（先に削除されていれば何もしない）。
      guard let todo = await ctx.select({ $0.todos.entities[id] }) else { return }
      await perform(ctx) { .updated(try await ctx.call(useCase.toggle, todo), generation: $0) }
    case .deleteTapped(let id):
      await perform(ctx) { generation in
        try await ctx.call(useCase.delete, id)
        return .deleted(id, generation: generation)
      }
    default:
      break
    }
  }

  /// 処理を始めた時点の世代を渡して処理を行い、結果を put する。失敗したらエラーの Action を put する。
  private func perform(
    _ ctx: SagaContext<TodoFeature.State, TodoFeature.Action>,
    _ operation: (_ generation: Int) async throws -> TodoFeature.Action?
  ) async {
    let generation = await ctx.select(\.generation)
    do {
      if let action = try await operation(generation) { await ctx.put(action) }
    } catch is CancellationError {
    } catch {
      await ctx.put(.failed(error.localizedDescription, generation: generation))
    }
  }
}
