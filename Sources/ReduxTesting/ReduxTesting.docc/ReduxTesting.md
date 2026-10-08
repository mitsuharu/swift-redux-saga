# ``ReduxTesting``

本物の Store と Saga を動かして、Action と State の変化を順に検証するテスト支援。

## Overview

```swift
let store = TestStore(initialState: Counter.initialState, reducer: Counter.reducer, saga: sagas.root)
try await store.send(.fetch) { $0.isLoading = true }
try store.receive(.fetched(42)) {
  $0.isLoading = false
  $0.count = 42
}
try await store.finish()
```

## Topics

- ``TestStore``
- ``TestStoreFailure``
