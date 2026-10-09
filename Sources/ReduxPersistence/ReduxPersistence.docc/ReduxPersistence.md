# ``ReduxPersistence``

State の一部を保存し、起動時に復元します。

## Overview

```swift
let persistence = Persistence<AppState, Settings>(
  key: "settings", storage: UserDefaultsStorage(), keyPath: \.settings)

let store = Store(
  initialState: persistence.restore(into: AppState()),
  reducer: appReducer,
  middleware: [PersistenceMiddleware<AppState, AppAction>(persistence)])
```

保存は State が変わってから少し待ってまとめて行います。その間にアプリが終了すると保存されないので、
バックグラウンドに入るときに ``PersistenceMiddleware/flush()`` を呼んでください。

## Topics

- ``Persistence``
- ``PersistenceMiddleware``
- ``PersistenceStorage``
- ``UserDefaultsStorage``
- ``FileStorage``
- ``InMemoryStorage``
