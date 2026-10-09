import Domain
import Redux
import ReduxMacros
import Saga

/// ログインの State・Action・reducer。ToDo（`TodoFeature`）を知らない。
@Slice
public enum AuthFeature {
  public struct State: Sendable, Equatable {
    /// ログイン中のユーザー。ログインしていなければ `nil`。
    public var user: User?
    public var isLoggingIn = false
    public var errorMessage: String?

    public init(user: User? = nil) {
      self.user = user
    }
  }

  public enum Action: Sendable, Equatable {
    // View から送る Action
    case loginTapped(name: String)
    case logoutTapped

    // Saga が送る Action
    case loggedIn(User)
    case loggedOut
    case failed(String)
  }

  public static func reduce(into state: inout State, action: Action) {
    switch action {
    case .loginTapped:
      state.isLoggingIn = true
      state.errorMessage = nil
    case .logoutTapped:
      break
    case .loggedIn(let user):
      state.isLoggingIn = false
      state.user = user
    case .loggedOut:
      state.user = nil
    case .failed(let message):
      state.isLoggingIn = false
      state.errorMessage = message
    }
  }
}

/// ログインの Saga。`TodoSagas` と同じく、子の State・Action だけで書く。
public struct AuthSagas: Sendable {
  private let useCase: AuthUseCase

  public init(useCase: AuthUseCase) {
    self.useCase = useCase
  }

  public var root: Saga<AuthFeature.State, AuthFeature.Action> {
    Saga("auth") { ctx in
      // ログインの処理中に届いたログインは無視する（ボタンは処理中に押せないが、念のため）。
      ctx.takeLeading(.case(\.loginTapped)) { ctx, name in
        do {
          guard let user = try await ctx.call(useCase.login, name) else {
            await ctx.put(.failed("Enter your name."))
            return
          }
          await ctx.put(.loggedIn(user))
        } catch is CancellationError {
        } catch {
          await ctx.put(.failed(error.localizedDescription))
        }
      }
      ctx.takeLeading(.action(.logoutTapped)) { ctx, _ in
        // ログアウトの通信に失敗しても、端末ではログアウトする。
        try? await ctx.call(useCase.logout)
        await ctx.put(.loggedOut)
      }
    }
  }
}
