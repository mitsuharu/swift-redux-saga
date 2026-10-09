import Redux
import ReduxMacros
import Saga

/// アプリ全体の State・Action。機能ごとの State・Action（`AuthFeature` / `TodoFeature`）を束ねるだけで、
/// 機能の処理は持たない。
public enum RootFeature {
  public struct State: Sendable, Equatable {
    public var auth = AuthFeature.State()
    public var todo = TodoFeature.State()

    public init() {}
  }

  @ActionCases
  public enum Action: Sendable, Equatable {
    case auth(AuthFeature.Action)
    case todo(TodoFeature.Action)
  }

  public static let initialState = State()

  /// 機能ごとの reducer を、親の State・Action に接続してまとめる。
  public static let reducer = Reducer<State, Action> {
    Reducer.slice(AuthFeature.self, state: \.auth, action: \.auth)
    Reducer.slice(TodoFeature.self, state: \.todo, action: \.todo)
    // ログアウトしたら、ToDo の一覧を消す（設定は残す）。
    Reducer { state, action in
      if case .auth(.loggedOut) = action {
        state.todo.todos = EntityState()
        state.todo.errorMessage = nil
      }
    }
  }
}

/// アプリ全体の Saga。機能ごとの Saga を、子の型のまま親に接続する。
///
/// - ログインの Saga は、アプリの起動中ずっと動かす。
/// - ToDo の Saga は、ログインしている間だけ動かす。ログアウトでキャンセルするので、
///   通信中の読み込みや保存も止まり、ログアウト後に古い結果が届かない。再ログインで起動し直す。
public struct RootSagas: Sendable {
  private let auth: AuthSagas
  private let todo: TodoSagas

  public init(auth: AuthSagas, todo: TodoSagas) {
    self.auth = auth
    self.todo = todo
  }

  public var root: Saga<RootFeature.State, RootFeature.Action> {
    Saga("root") { ctx in
      ctx.fork(auth.root, state: \.auth, action: \.auth, embed: RootFeature.Action.auth)
      while true {
        if await ctx.select(\.auth.user) == nil {
          _ = try await ctx.take(.case(\.auth?.loggedIn))
        }
        let session = ctx.fork(
          todo.root, state: \.todo, action: \.todo, embed: RootFeature.Action.todo)
        _ = try await ctx.take(.case(\.auth?.loggedOut))
        ctx.cancel(session)
      }
    }
  }
}
