import Domain
import Foundation
import Testing

@Suite struct TodoUseCaseTests {
  private let useCase = TodoUseCase(repository: InMemoryTodoRepository(latency: .zero))

  @Test func addSavesATodoWithTheTrimmedTitle() async throws {
    let todo = try await useCase.add(title: "  buy milk \n")
    #expect(todo?.title == "buy milk")
    #expect(try await useCase.load().map(\.title) == ["buy milk"])
  }

  @Test func addIgnoresABlankTitle() async throws {
    #expect(try await useCase.add(title: "   ") == nil)
    #expect(try await useCase.load().isEmpty)
  }

  @Test func loadReturnsTodosInCreationOrder() async throws {
    let old = Todo(title: "old", createdAt: Date(timeIntervalSince1970: 0))
    let new = Todo(title: "new", createdAt: Date(timeIntervalSince1970: 100))
    let useCase = TodoUseCase(
      repository: InMemoryTodoRepository(todos: [new, old], latency: .zero))
    #expect(try await useCase.load().map(\.title) == ["old", "new"])
  }

  @Test func toggleFlipsAndSavesTheDoneFlag() async throws {
    let todo = try #require(try await useCase.add(title: "a"))
    let toggled = try await useCase.toggle(todo)
    #expect(toggled.isDone)
    #expect(try await useCase.load().first?.isDone == true)
  }

  @Test func deleteRemovesTheTodo() async throws {
    let todo = try #require(try await useCase.add(title: "a"))
    try await useCase.delete(todo.id)
    #expect(try await useCase.load().isEmpty)
  }
}
