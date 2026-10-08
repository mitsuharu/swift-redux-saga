import Domain
import Redux
import ReduxSaga
import Saga

/// アプリの Store を組み立てる。依存（UseCase）はここで注入する。
@MainActor
public enum AppStore {
  public typealias State = TodoFeature.State
  public typealias Action = TodoFeature.Action

  /// Store を作り、Saga を起動する。
  ///
  /// - Parameter useCase: Saga が使う UseCase。プレビューやテストでは差し替える。
  public static func make(useCase: TodoUseCase) -> Store<State, Action> {
    let sagaMiddleware = SagaMiddleware<State, Action>()
    let store = Store(
      initialState: TodoFeature.initialState,
      reducer: TodoFeature.reducer,
      middleware: [sagaMiddleware]
    )
    sagaMiddleware.run(TodoSagas(useCase: useCase).root)
    return store
  }
}
