# ``Redux``

Swift 6 の Redux（Redux Toolkit を参考にした実装）。

## Overview

`Store` は `@MainActor` で隔離された `Observable` なコンテナです。Action を `Reducer`（同期の純粋関数）に通して State を更新します。
`store.count` のように State のプロパティを直接読むと、そのプロパティが変わったときだけ SwiftUI や UIKit が再描画します。

```swift
let store = Store(initialState: Counter.initialState, reducer: Counter.reducer)
store.dispatch(.increment)
print(store.count)
```

## Topics

### Store

- ``Store``
- ``ObservationToken``

### Reducer と Slice

- ``Reducer``
- ``ReducerBuilder``
- ``Slice``

### Middleware

- ``Middleware``
- ``MiddlewareAPI``
- ``MiddlewareBuilder``

### 入力欄の Binding

- ``BindableState``
- ``BindingAction``
- ``BindableAction``

### Redux Toolkit 相当

- ``Selector``
- ``createSelector(_:result:)``
- ``EntityState``
- ``EntityAdapter``
