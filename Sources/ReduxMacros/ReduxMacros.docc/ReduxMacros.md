# ``ReduxMacros``

Action の取り出しと Slice の定義を短く書くためのマクロ。

## Overview

``ActionCases()`` は enum の case ごとに関連値を取り出すプロパティを生成し、`ActionPattern.case(_:)` や
`Reducer.slice(_:state:action:)` にキーパスで渡せるようにします。``Slice()`` は Slice の定型コードを補います。

```swift
@Slice
enum Counter {
  struct State: Sendable, Equatable { var count = 0 }
  enum Action: Sendable { case increment, add(Int) }
  static func reduce(into state: inout State, action: Action) { ... }
}

ctx.takeEvery(.case(\.add)) { ctx, value in ... }
```

マクロを使わなくても、すべての機能を使えます。

## Topics

- ``ActionCases()``
- ``Slice()``
