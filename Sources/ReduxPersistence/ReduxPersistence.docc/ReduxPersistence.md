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

## Topics

- ``Persistence``
- ``PersistenceMiddleware``
- ``PersistenceStorage``
- ``UserDefaultsStorage``
- ``FileStorage``
- ``InMemoryStorage``
