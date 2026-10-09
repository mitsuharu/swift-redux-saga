import Domain
import Redux
import ReduxPersistence
import ReduxSaga
import Saga

/// アプリの Store を組み立てる。依存（UseCase、設定の保存先）はここで注入する。
@MainActor
public enum AppStore {
  public typealias State = RootFeature.State
  public typealias Action = RootFeature.Action

  /// 設定（Preferences）を保存する設定。
  static func preferencesPersistence(storage: some PersistenceStorage)
    -> Persistence<State, TodoFeature.Preferences>
  {
    Persistence(key: "preferences", storage: storage, keyPath: \.todo.preferences)
  }

  /// Store と、アプリのライフサイクルに合わせて呼ぶ処理。
  @MainActor
  public struct Components {
    public let store: Store<State, Action>
    let sagaMiddleware: SagaMiddleware<State, Action>
    let persistenceMiddleware: PersistenceMiddleware<State, Action>

    /// 保存を待っている設定をすぐに保存する。
    ///
    /// 設定は変わってから少し待ってまとめて保存するため、その間にアプリが終了すると保存されない。
    /// バックグラウンドに入るときに呼ぶ。
    public func flush() async {
      await persistenceMiddleware.flush()
    }
  }

  /// Store を作り、Saga を起動する。Store と、Saga と保存のミドルウェアを返す。
  ///
  /// アプリはバックグラウンドに入るときに ``Components/flush()`` を呼ぶ。テストは Saga を待ち合わせるために
  /// ミドルウェアを使う。
  public static func make(
    useCase: TodoUseCase,
    authUseCase: AuthUseCase = AuthUseCase(repository: InMemoryAuthRepository()),
    storage: some PersistenceStorage = UserDefaultsStorage()
  ) -> Components {
    let persistence = preferencesPersistence(storage: storage)
    let sagaMiddleware = SagaMiddleware<State, Action>()
    let persistenceMiddleware = PersistenceMiddleware<State, Action>(persistence)
    let store = Store(
      // 保存した設定を復元してから始める。
      initialState: persistence.restore(into: RootFeature.initialState),
      reducer: RootFeature.reducer,
      middleware: [
        // デバッグビルドでだけ Action を os.Logger に出力する。
        LoggingMiddleware(),
        // 設定が変わったら保存する。
        persistenceMiddleware,
        sagaMiddleware,
      ]
    )
    sagaMiddleware.run(
      RootSagas(auth: AuthSagas(useCase: authUseCase), todo: TodoSagas(useCase: useCase)).root)
    return Components(
      store: store, sagaMiddleware: sagaMiddleware, persistenceMiddleware: persistenceMiddleware)
  }
}
