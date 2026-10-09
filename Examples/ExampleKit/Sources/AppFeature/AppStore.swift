import Domain
import Redux
import ReduxPersistence
import ReduxSaga
import Saga

/// アプリの Store を組み立てる。依存（UseCase、設定の保存先）はここで注入する。
@MainActor
public enum AppStore {
  public typealias State = TodoFeature.State
  public typealias Action = TodoFeature.Action

  /// 設定（Preferences）を保存する設定。
  public static func preferencesPersistence(storage: some PersistenceStorage)
    -> Persistence<State, TodoFeature.Preferences>
  {
    Persistence(key: "preferences", storage: storage, keyPath: \.preferences)
  }

  /// Store を作り、Saga を起動する。
  ///
  /// - Parameters:
  ///   - useCase: Saga が使う UseCase。プレビューやテストでは差し替える。
  ///   - storage: 設定の保存先。
  public static func make(
    useCase: TodoUseCase, storage: some PersistenceStorage = UserDefaultsStorage()
  ) -> Store<State, Action> {
    makeComponents(useCase: useCase, storage: storage).store
  }

  /// Store と、Saga を載せたミドルウェアを作る。テストで Saga を待ち合わせるために、ミドルウェアも返す。
  static func makeComponents(
    useCase: TodoUseCase, storage: some PersistenceStorage
  ) -> (store: Store<State, Action>, sagaMiddleware: SagaMiddleware<State, Action>) {
    let persistence = preferencesPersistence(storage: storage)
    let sagaMiddleware = SagaMiddleware<State, Action>()
    let store = Store(
      // 保存した設定を復元してから始める。
      initialState: persistence.restore(into: TodoFeature.initialState),
      reducer: TodoFeature.reducer,
      middleware: [
        // デバッグビルドでだけ Action を os.Logger に出力する。
        LoggingMiddleware(),
        // 設定が変わったら保存する。
        PersistenceMiddleware<State, Action>(persistence),
        sagaMiddleware,
      ]
    )
    sagaMiddleware.run(TodoSagas(useCase: useCase).root)
    return (store, sagaMiddleware)
  }
}
