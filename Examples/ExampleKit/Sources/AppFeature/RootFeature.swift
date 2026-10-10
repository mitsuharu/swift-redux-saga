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
    // ログアウトしたら、ToDo の一覧を消し（設定は残す）、世代を進める。
    // 世代を進めると、ログアウト前に始まった処理の結果が後から届いても、ToDo の reducer が捨てる。
    Reducer { state, action in
      if case .auth(.loggedOut) = action {
        state.todo.todos = EntityState()
        state.todo.isLoading = false
        state.todo.errorMessage = nil
        state.todo.generation += 1
      }
    }
  }
}

/// アプリ全体の Saga。機能ごとの Saga を、子の型のまま親に接続する。
///
/// - ログインの Saga は、アプリの起動中ずっと動かす。
/// - ToDo の Saga は、ログインしている間だけ動かす。ログアウトでキャンセルして通信中の読み込みや保存を止め、
///   再ログインで起動し直す。
/// - キャンセルだけでは、通信が終わってから put するまでの間にログアウトされた結果が届き得るので、
///   ToDo の結果には世代を含め、ログアウトで世代を進めて捨てる（`TodoFeature.State.generation`）。
public struct RootSagas: Sendable {
  private let auth: AuthSagas
  private let todo: TodoSagas

  public init(auth: AuthSagas, todo: TodoSagas) {
    self.auth = auth
    self.todo = todo
  }

  public var root: Saga<RootFeature.State, RootFeature.Action> {
    Saga("root") { ctx in
      // select は非同期なので、State を読んでから take を登録する間にも認証が変わり得る。
      // 先に購読し、ログイン・ログアウトの完了をセッションの切り替え中も保持する。
      let authEvents = ctx.actionChannel(
        ActionPattern<RootFeature.Action, AuthFeature.Action>.case(\.auth).where {
          switch $0 {
          case .loggedIn, .loggedOut: true
          default: false
          }
        })
      ctx.fork(auth.root, state: \.auth, action: \.auth, embed: RootFeature.Action.auth)
      while true {
        if await ctx.select(\.auth.user) == nil {
          guard try await authEvents.first(where: { $0.loggedIn != nil }) != nil else { return }
        }
        let session = ctx.fork(
          todo.root, state: \.todo, action: \.todo, embed: RootFeature.Action.todo)
        guard try await authEvents.first(where: { $0 == .loggedOut }) != nil else { return }
        ctx.cancel(session)
      }
    }
  }
}
