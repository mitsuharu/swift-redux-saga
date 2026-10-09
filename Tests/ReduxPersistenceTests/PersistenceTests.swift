import Foundation
import InternalPrimitives
import Redux
import ReduxPersistence
import SagaTesting
import Testing

private struct Settings: Sendable, Equatable, Codable {
  var theme = "light"
  var fontSize = 14
}

private struct AppState: Sendable, Equatable {
  var settings = Settings()
  var isLoading = false
}

private enum Action: Sendable {
  case setTheme(String)
  case setLoading(Bool)
}

private let reducer = Reducer<AppState, Action> { state, action in
  switch action {
  case .setTheme(let theme): state.settings.theme = theme
  case .setLoading(let isLoading): state.isLoading = isLoading
  }
}

private func makePersistence(_ storage: InMemoryStorage, version: Int = 1)
  -> Persistence<AppState, Settings>
{
  Persistence(key: "settings", storage: storage, version: version, keyPath: \.settings)
}

@Suite struct PersistenceTests {
  @Test func restoreReturnsTheGivenStateWhenNothingIsSaved() {
    let persistence = makePersistence(InMemoryStorage())
    #expect(persistence.restore(into: AppState()) == AppState())
  }

  @Test func savedSnapshotIsRestoredIntoTheState() throws {
    let storage = InMemoryStorage()
    var state = AppState()
    state.settings.theme = "dark"
    state.isLoading = true
    try makePersistence(storage).save(state)

    let restored = makePersistence(storage).restore(into: AppState())
    #expect(restored.settings.theme == "dark")
    #expect(restored.isLoading == false)  // 保存していない部分は初期値のまま
  }

  @Test func corruptedDataIsIgnoredAndReported() {
    let storage = InMemoryStorage(["settings": Data("not json".utf8)])
    var reported: (any Error)?
    let restored = makePersistence(storage).restore(into: AppState()) { reported = $0 }
    #expect(restored == AppState())
    #expect(reported != nil)
  }

  @Test func dataSavedWithAnOlderVersionIsMigrated() throws {
    let storage = InMemoryStorage()
    // 以前は theme だけを文字列として保存していた（version 1）。
    let old = Persistence<AppState, String>(
      key: "settings", storage: storage, version: 1,
      snapshot: { $0.settings.theme }, apply: { $0.settings.theme = $1 })
    var state = AppState()
    state.settings.theme = "dark"
    try old.save(state)

    let current = Persistence<AppState, Settings>(
      key: "settings", storage: storage, version: 2, keyPath: \.settings
    ) { fromVersion, data in
      guard fromVersion == 1 else { return nil }
      let theme = try JSONDecoder().decode(String.self, from: data)
      return Settings(theme: theme, fontSize: 14)
    }
    #expect(current.restore(into: AppState()).settings == Settings(theme: "dark", fontSize: 14))
  }

  @Test func dataFromAnUnknownVersionWithoutMigrationIsNotRestored() throws {
    let storage = InMemoryStorage()
    try makePersistence(storage, version: 1).save(AppState(settings: Settings(theme: "dark")))
    #expect(makePersistence(storage, version: 2).restore(into: AppState()) == AppState())
  }

  @Test func clearRemovesTheSavedData() throws {
    let storage = InMemoryStorage()
    let persistence = makePersistence(storage)
    try persistence.save(AppState())
    try persistence.clear()
    #expect(storage.values.isEmpty)
  }

  @Test func wholeStateCanBePersistedWhenItIsCodable() throws {
    let storage = InMemoryStorage()
    let persistence = Persistence<Settings, Settings>(key: "all", storage: storage)
    try persistence.save(Settings(theme: "dark", fontSize: 20))
    #expect(persistence.restore(into: Settings()) == Settings(theme: "dark", fontSize: 20))
  }

  @Test func fileStorageWritesAndReadsFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = FileStorage(directory: directory)
    #expect(try storage.load(key: "a") == nil)
    try storage.save(Data("x".utf8), key: "a")
    #expect(try storage.load(key: "a") == Data("x".utf8))
    try storage.remove(key: "a")
    #expect(try storage.load(key: "a") == nil)
  }

  @Test func userDefaultsStorageWritesAndReadsData() throws {
    let suite = "swift-redux-saga-tests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let storage = UserDefaultsStorage(suiteName: suite)
    try storage.save(Data("x".utf8), key: "a")
    #expect(try storage.load(key: "a") == Data("x".utf8))
    try storage.remove(key: "a")
    #expect(try storage.load(key: "a") == nil)
  }
}

@MainActor
@Suite struct PersistenceMiddlewareTests {
  @Test func changesAreSavedOnceAfterTheDebounce() async throws {
    let storage = InMemoryStorage()
    let clock = TestClock()
    let middleware = PersistenceMiddleware<AppState, Action>(
      makePersistence(storage), debounce: .milliseconds(500), clock: clock)
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])

    store.dispatch(.setTheme("dark"))
    store.dispatch(.setTheme("blue"))
    #expect(storage.values.isEmpty)
    await middleware.flush()
    #expect(makePersistence(storage).restore(into: AppState()).settings.theme == "blue")
  }

  @Test func changesOutsideTheSnapshotDoNotScheduleASave() async {
    let storage = InMemoryStorage()
    let middleware = PersistenceMiddleware<AppState, Action>(
      makePersistence(storage), clock: TestClock())
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])
    store.dispatch(.setLoading(true))
    await middleware.flush()
    #expect(storage.values.isEmpty)
  }

  @Test func theLatestStateIsSavedWhenTheDebounceElapses() async throws {
    let storage = InMemoryStorage()
    let clock = TestClock()
    let middleware = PersistenceMiddleware<AppState, Action>(
      makePersistence(storage), debounce: .seconds(1), clock: clock)
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])
    store.dispatch(.setTheme("dark"))
    while clock.sleeperCount == 0 { await Task.yield() }
    clock.advance(by: .seconds(1))
    // 保存はメインアクター外の Task で行われるので、保存されるまで待つ。
    while storage.values.isEmpty { await Task.yield() }
    #expect(makePersistence(storage).restore(into: AppState()).settings.theme == "dark")
  }
}

/// 最初の書き込みを、`release()` を呼ぶまで止める保存先。
private final class GatedStorage: PersistenceStorage {
  // DispatchSemaphore を使わないのは、Linux の Foundation では Sendable でないため。
  private let isReleased = Locked(false)
  private let saves = Locked<[Data]>([])
  private let latest = Locked<Data?>(nil)
  private let completed = Locked(0)

  var startedSaves: Int { saves.withLock { $0.count } }
  var completedSaves: Int { completed.withLock { $0 } }

  func release() { isReleased.withLock { $0 = true } }

  func load(key: String) throws -> Data? { latest.withLock { $0 } }

  func save(_ data: Data, key: String) throws {
    let isFirst = saves.withLock { saves -> Bool in
      saves.append(data)
      return saves.count == 1
    }
    while isFirst, !isReleased.withLock({ $0 }) {
      Thread.sleep(forTimeInterval: 0.001)
    }
    latest.withLock { $0 = data }
    completed.withLock { $0 += 1 }
  }

  func remove(key: String) throws { latest.withLock { $0 = nil } }
}

@MainActor
@Suite struct PersistenceSaveOrderTests {
  @Test func aNewerStateIsNotOverwrittenByASlowerOlderSave() async throws {
    let storage = GatedStorage()
    let clock = TestClock()
    let middleware = PersistenceMiddleware<AppState, Action>(
      Persistence(key: "settings", storage: storage, keyPath: \.settings),
      debounce: .seconds(1), clock: clock)
    let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])

    store.dispatch(.setTheme("dark"))
    while clock.sleeperCount == 0 { await Task.yield() }
    clock.advance(by: .seconds(1))
    // 古い State の書き込みが始まり、止まっている。
    while storage.startedSaves == 0 { await Task.yield() }

    store.dispatch(.setTheme("blue"))
    let flushed = Task { await middleware.flush() }
    storage.release()
    await flushed.value
    // 止めていた古い書き込みも終わってから、残った値を確かめる。
    while storage.completedSaves < storage.startedSaves { await Task.yield() }

    let restored = Persistence<AppState, Settings>(
      key: "settings", storage: storage, keyPath: \.settings
    ).restore(into: AppState())
    #expect(restored.settings.theme == "blue")
  }
}

@MainActor
@Suite struct PersistenceMemoryTests {
  @Test func storeWithAPendingSaveIsReleased() async {
    weak var weakStore: Store<AppState, Action>?
    weak var weakMiddleware: PersistenceMiddleware<AppState, Action>?
    let storage = InMemoryStorage()
    do {
      let middleware = PersistenceMiddleware<AppState, Action>(
        makePersistence(storage), debounce: .seconds(100), clock: TestClock())
      let store = Store(initialState: AppState(), reducer: reducer, middleware: [middleware])
      weakStore = store
      weakMiddleware = middleware
      store.dispatch(.setTheme("dark"))  // 保存を待っている状態で手放す
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while weakStore != nil || weakMiddleware != nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(weakStore == nil)
    #expect(weakMiddleware == nil)
  }
}
