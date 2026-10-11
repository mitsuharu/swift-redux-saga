# State の永続化（ReduxPersistence）

アプリを終了しても残しておきたい値、たとえばユーザーの設定や書きかけの下書きは、State の一部を端末に保存し、次の起動時に復元します。`ReduxPersistence` は、そのための設定（`Persistence`）と、State が変わったときに保存するミドルウェア（`PersistenceMiddleware`）を提供します。

この文書では、何を保存するかの選び方、保存先、保存されるタイミング、データの削除と保存形式の変更、テストの書き方を順に説明します。

## 全体の流れ

永続化に関わる部品は 3 つです。

- `Persistence`: State のどの部分を、どこに（保存先とキー）保存するかの設定です。
- `persistence.restore(into:)`: 起動時に保存した値を読み、State の初期値に反映します。
- `PersistenceMiddleware`: State が変わったら、`Persistence` で選んだ部分を保存します。

組み立ては次のようになります。

```swift
import ReduxPersistence

let persistence = Persistence<AppState, Settings>(
  key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)

let persistenceMiddleware = PersistenceMiddleware<AppState, AppAction>(persistence)
let store = Store(
  initialState: persistence.restore(into: AppState()),  // 起動時に復元
  reducer: appReducer,
  middleware: [persistenceMiddleware]                    // 変わったら保存
)
```

`Persistence` を作っただけでは、State は保存されません。保存されるのは、`Persistence` で選んだ部分だけです。State の全部が自動で保存されることはなく、保存しない値はそもそも選ばなければよい、という考え方です。

## 保存する部分を選ぶ

保存する部分は、次の 3 通りのどれかで選びます。保存する値の型（スナップショット）は `Codable` で、`Equatable` にしておくことをおすすめします（理由は「保存のタイミング」で説明します）。

### プロパティを 1 つ選ぶ

いちばん多いのは、State のプロパティを 1 つ、キーパスで選ぶ形です。保存するときはそのプロパティを読み、復元するときはそのプロパティに書き戻します。

```swift
struct Settings: Codable, Sendable, Equatable {
  var theme = "system"
  var fontSize = 14
}

struct AppState: Sendable, Equatable {
  var settings = Settings()   // 保存する
  var todos: [Todo] = []      // 保存しない
  var isLoading = false       // 保存しない
}

let persistence = Persistence<AppState, Settings>(
  key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)
```

保存したい値を 1 つの型にまとめておけば、この形で済みます。サンプル（`Examples/ExampleKit/Sources/AppFeature/AppStore.swift`）も、ToDo の表示設定（`\.todo.preferences`）だけをこの形で保存しています。

### 複数のプロパティを選ぶ

保存したい値が State のあちこちにある場合は、保存用の型を作り、State との変換を `snapshot` と `apply` に書きます。`snapshot` は State から保存する値を取り出す関数、`apply` は復元した値を State に書き戻す関数です。

```swift
struct SavedTodos: Codable, Sendable, Equatable {
  var todos: [Todo]
  var filter: Filter
}

let persistence = Persistence<AppState, SavedTodos>(
  key: "todos",
  storage: FileStorage(directory: .applicationSupportDirectory),
  snapshot: { SavedTodos(todos: $0.todos, filter: $0.filter) },
  apply: { state, saved in
    state.todos = saved.todos
    state.filter = saved.filter
  }
)
```

保存用の型に入れなかった値は、保存も復元もされません。State の構造と保存形式を切り離せるので、State のプロパティの名前を変えたり、置き場所を移したりしても、保存したデータはそのまま読めます。

### State 全体を保存する

State が `Codable` なら、State をまるごと保存することもできます。

```swift
let persistence = Persistence<AppState, AppState>(key: "app", storage: UserDefaultsStorage())
```

手軽ですが、読み込み中かどうかやエラーのような一時的な値まで保存され、次の起動時に復元されてしまいます。読み込み中のまま起動して、いつまでもインジケーターが回り続ける、といった不具合のもとになるので、通常はプロパティを選ぶ形をおすすめします。

### 保存しないほうがよいもの

次のような値は保存しないでください。

- 読み込み中かどうか、エラー、表示中のアラートなど、その場かぎりの状態
- サーバーから取得し直せるデータ（保存すると、古いデータを表示する原因になります）
- パスワードやトークンなどの秘密の値（`UserDefaults` やファイルは暗号化されません。Keychain に保存してください。「保存先」の節を参照）

## 保存先

保存先は `PersistenceStorage` プロトコルに準拠した型で、次の 3 つを用意しています。

| 保存先 | 向いている用途 |
| --- | --- |
| `UserDefaultsStorage` | 設定のような小さなデータ。`suiteName:` で App Group と共有もできる |
| `FileStorage` | 一覧などの大きなデータ。キーごとに `<キー>.json` のファイルを作る |
| `InMemoryStorage` | テストやプレビュー。アプリを終了すると消える |

`FileStorage` は、書き込みの途中でアプリが終了しても壊れたファイルが残らないよう、一時ファイルに書いてから置き換えます。保存先のディレクトリがなければ、最初の保存のときに作ります。

ほかの場所に保存したい場合は、`PersistenceStorage` に準拠した型を作ります。必要なのは、読み込み・保存・削除の 3 つのメソッドだけです。たとえば Keychain に保存する場合は次のようになります。

```swift
import Security

struct KeychainStorage: PersistenceStorage {
  let service: String

  func load(key: String) throws -> Data? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return result as? Data
  }

  func save(_ data: Data, key: String) throws {
    let status = SecItemUpdate(
      baseQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery(key)
      query[kSecValueData as String] = data
      let added = SecItemAdd(query as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }

  func remove(key: String) throws {
    let status = SecItemDelete(baseQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}

struct KeychainError: Error {
  let status: OSStatus
}
```

### 保存先を分ける

`Persistence` とミドルウェアは、いくつでも作れます。保存先やキーを分けたい場合は、組を分けて、ミドルウェアを両方とも Store に渡します。

```swift
let settingsPersistence = Persistence<AppState, Settings>(
  key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)
let todosPersistence = Persistence<AppState, [Todo]>(
  key: "todos", storage: FileStorage(directory: .applicationSupportDirectory), keyPath: \.todos)

let settingsMiddleware = PersistenceMiddleware<AppState, AppAction>(settingsPersistence)
let todosMiddleware = PersistenceMiddleware<AppState, AppAction>(todosPersistence)

var initialState = AppState()
initialState = settingsPersistence.restore(into: initialState)
initialState = todosPersistence.restore(into: initialState)

let store = Store(
  initialState: initialState,
  reducer: appReducer,
  middleware: [settingsMiddleware, todosMiddleware]
)
```

設定を変えたときは設定だけ、ToDo を変えたときは ToDo だけが保存されます。サイズの大きいデータと小さいデータを分けておくと、小さな変更のたびに大きなデータを書き直さずに済みます。

## 保存のタイミング

`PersistenceMiddleware` は、Action を処理するたびに、保存する部分が変わったかを調べます。変わっていなければ何もしません。保存用の型が `Equatable` なら値を比べて判断します。`Equatable` でなければ比べられないので、Action のたびに保存の予約をします。保存用の型を `Equatable` にしておくのは、関係のない変更で書き込みが起きないようにするためです。

保存はすぐには行わず、最後に変わってから少し待って（既定では 0.5 秒）1 回だけ行います。文字の入力のように続けて変わる場合でも、書き込みは入力が止まった後の 1 回で済みます。待つ時間は `debounce:` で変えられます。保存（エンコードと書き込み）はメインアクターの外で行うので、画面の操作を止めません。

```swift
let persistenceMiddleware = PersistenceMiddleware<AppState, AppAction>(
  persistence, debounce: .seconds(1))
```

待っている間にアプリが終了すると、その変更は保存されません。そのため、アプリがバックグラウンドに入るときに `flush()` を呼び、待たずに保存します。`flush()` は、書き込み中の保存が終わるまで待ってから戻ります。

```swift
// SwiftUI
@Environment(\.scenePhase) private var scenePhase

var body: some Scene {
  WindowGroup { RootView() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await persistenceMiddleware.flush() } }
    }
}

// UIKit（SceneDelegate）
func sceneDidEnterBackground(_ scene: UIScene) {
  Task { await persistenceMiddleware.flush() }
}
```

復元（`restore(into:)`）は、Store を作る前にメインアクターの上で同期的に行います。大きなデータを `FileStorage` から読むと起動が遅くなるので、起動時に必要なデータだけを保存するようにしてください。

## 保存したデータを消す

ログアウトのように、保存したデータを消すときは、ミドルウェアの `clear()` を使います。

```swift
try await persistenceMiddleware.clear()
```

`Persistence` にも `clear()` がありますが、ミドルウェアを使っている場合は使わないでください。保存を待っている State があると、消した後に書き込まれ、消したはずのデータが戻ってしまいます。ミドルウェアの `clear()` は、保存を待っている State を捨て、書き込み中の保存が終わってから消します。`clear()` を待っている間に新しく予約された保存は、削除が終わってから行います。

ログアウトでは、State の側もリセットしてください。`clear()` が消すのは保存したデータだけで、Store の State はそのまま残ります。

## 保存形式を変える

アプリを更新して保存用の型を変えると、以前のバージョンで保存したデータが読めなくなることがあります。そこで、保存するときにはバージョン（`version`）を一緒に書き込んでいます。保存形式を変えたときは `version` を上げ、`migrate` で古い形式から新しい形式に変換します。

たとえば、バージョン 1 では `theme` だけを保存していて、バージョン 2 で `fontSize` を加えた場合は、次のように書きます。

```swift
struct Settings: Codable, Sendable, Equatable {
  var theme: String
  var fontSize: Int
}

/// バージョン 1 の保存形式。
private struct SettingsV1: Decodable {
  var theme: String
}

let persistence = Persistence<AppState, Settings>(
  key: "settings",
  storage: UserDefaultsStorage(),
  version: 2,
  keyPath: \.settings,
  migrate: { fromVersion, data in
    switch fromVersion {
    case 1:
      let old = try JSONDecoder().decode(SettingsV1.self, from: data)
      return Settings(theme: old.theme, fontSize: 14)
    default:
      return nil  // 変換できない形式は捨てて、初期値で始める
    }
  }
)
```

`migrate` に渡されるのは、古いバージョンで保存したスナップショットの JSON です。`nil` を返すと復元せず、State の初期値のまま始まります。変換した値は、次に保存する部分が変わったときに、新しいバージョンで保存されます。

保存形式を変えずにプロパティを足すだけなら、新しいプロパティを Optional にするか、`init(from:)` で既定値を補うことで、`version` を上げずに済ませることもできます。

## エラーの扱い

保存したデータが読めない場合（壊れている、変換できないなど）、`restore(into:)` は保存した値を使わず、渡した初期値をそのまま返します。アプリは起動できますが、原因を知りたい場合は `onError:` でログに出してください。

```swift
let initialState = persistence.restore(into: AppState()) { error in
  logger.error("設定を復元できませんでした: \(error)")
}
```

保存に失敗した場合も同じように、ミドルウェアの `onError:` で受け取れます。保存の失敗で Action の処理が止まることはありません。

```swift
let persistenceMiddleware = PersistenceMiddleware<AppState, AppAction>(persistence) { error in
  logger.error("設定を保存できませんでした: \(error)")
}
```

## テスト

テストでは、保存先に `InMemoryStorage` を渡します。保存したデータは `values` で確かめられます。待つ時間は `TestClock` で制御し、`flush()` を呼べば、時間を進めなくても保存を終わらせられます。

```swift
import ReduxPersistence
import SagaTesting
import Testing

@MainActor
@Test func theThemeIsSaved() async {
  let storage = InMemoryStorage()
  let persistence = Persistence<AppState, Settings>(
    key: "settings", storage: storage, keyPath: \.settings)
  let middleware = PersistenceMiddleware<AppState, AppAction>(persistence, clock: TestClock())
  let store = Store(initialState: AppState(), reducer: appReducer, middleware: [middleware])

  store.dispatch(.setTheme("dark"))
  await middleware.flush()

  #expect(persistence.restore(into: AppState()).settings.theme == "dark")
}
```

保存しない値が変わったときに保存されないことも、同じように確かめられます（`flush()` の後に `storage.values` が空のまま）。
