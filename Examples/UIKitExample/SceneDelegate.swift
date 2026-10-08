import AppFeature
import Domain
import Foundation
import UIKit

/// アプリ本体は View と Store の組み立てだけを持つ。依存（リポジトリ）はここで決めて注入する。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  private let store = AppStore.make(
    useCase: TodoUseCase(
      repository: InMemoryTodoRepository(todos: [
        Todo(title: "Read the design doc", createdAt: .now.addingTimeInterval(-60)),
        Todo(title: "Write a saga", createdAt: .now),
      ])
    )
  )

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UINavigationController(
      rootViewController: TodoViewController(store: store))
    window.makeKeyAndVisible()
    self.window = window
  }
}
