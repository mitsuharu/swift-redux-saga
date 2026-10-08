import Redux
import Testing

private struct Todo: Sendable, Equatable, Identifiable {
  var id: Int
  var title: String
  var done = false
}

private let byInsertion = EntityAdapter<Int, Todo>()
private let byTitle = EntityAdapter<Int, Todo>(sortedBy: { $0.title < $1.title })
private let byKeyPath = EntityAdapter<Int, Todo>(id: \.id)

@Suite struct EntityAdapterTests {
  @Test func addOneAppendsAndIgnoresAnExistingID() {
    var state = EntityState<Int, Todo>()
    byInsertion.addOne(Todo(id: 1, title: "a"), to: &state)
    byInsertion.addOne(Todo(id: 2, title: "b"), to: &state)
    byInsertion.addOne(Todo(id: 1, title: "changed"), to: &state)
    #expect(state.ids == [1, 2])
    #expect(state.entities[1]?.title == "a")
  }

  @Test func setManyInsertsOrReplaces() {
    var state = EntityState<Int, Todo>()
    byInsertion.addOne(Todo(id: 1, title: "a"), to: &state)
    byInsertion.setMany([Todo(id: 1, title: "A"), Todo(id: 3, title: "c")], in: &state)
    #expect(byInsertion.all(in: state).map(\.title) == ["A", "c"])
  }

  @Test func setAllReplacesEverything() {
    var state = EntityState<Int, Todo>()
    byInsertion.addMany([Todo(id: 1, title: "a"), Todo(id: 2, title: "b")], to: &state)
    byInsertion.setAll([Todo(id: 9, title: "z")], in: &state)
    #expect(state.ids == [9])
    #expect(state.entities.count == 1)
  }

  @Test func updateOneChangesTheEntityInPlace() {
    var state = EntityState<Int, Todo>()
    byInsertion.addOne(Todo(id: 1, title: "a"), to: &state)
    byInsertion.updateOne(1, in: &state) { $0.done = true }
    byInsertion.updateOne(42, in: &state) { $0.done = true }  // ない ID は無視
    #expect(byInsertion.entity(1, in: state)?.done == true)
    #expect(byInsertion.count(in: state) == 1)
  }

  @Test func updateOneMovesTheEntityWhenItsIDChanges() {
    var state = EntityState<Int, Todo>()
    byInsertion.addMany([Todo(id: 1, title: "a"), Todo(id: 2, title: "b")], to: &state)
    byInsertion.updateOne(1, in: &state) { $0.id = 10 }
    #expect(state.ids == [10, 2])
    #expect(state.entities[1] == nil)
    #expect(state.entities[10]?.title == "a")
  }

  @Test func removeManyDeletesTheEntitiesAndTheirIDs() {
    var state = EntityState<Int, Todo>()
    byInsertion.addMany((1...4).map { Todo(id: $0, title: "\($0)") }, to: &state)
    byInsertion.removeMany([1, 3], from: &state)
    byInsertion.removeOne(99, from: &state)
    #expect(state.ids == [2, 4])
    #expect(Set(state.entities.keys) == [2, 4])
    byInsertion.removeAll(from: &state)
    #expect(state == EntityState())
  }

  @Test func sortedAdapterKeepsIDsInOrderAfterEveryChange() {
    var state = EntityState<Int, Todo>()
    byTitle.addMany([Todo(id: 1, title: "c"), Todo(id: 2, title: "a")], to: &state)
    #expect(state.ids == [2, 1])
    byTitle.setOne(Todo(id: 3, title: "b"), in: &state)
    #expect(state.ids == [2, 3, 1])
    byTitle.updateOne(2, in: &state) { $0.title = "z" }
    #expect(byTitle.all(in: state).map(\.title) == ["b", "c", "z"])
  }

  @Test func keyPathAndIdentifiableAdaptersUseTheSameID() {
    var a = EntityState<Int, Todo>()
    var b = EntityState<Int, Todo>()
    byKeyPath.addOne(Todo(id: 5, title: "x"), to: &a)
    byInsertion.addOne(Todo(id: 5, title: "x"), to: &b)
    #expect(a == b)
  }
}
