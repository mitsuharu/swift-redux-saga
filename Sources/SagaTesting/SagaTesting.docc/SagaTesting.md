# ``SagaTesting``

Saga の結果を、実時間に依存せずに検証するためのテスト支援。

## Overview

``SagaTester`` は Store なしで Saga を動かし、送った Action に対して Saga が発行した Action と State を検証します。
待ち合わせは「すべての Saga が Effect で止まったか」で行い、``TestClock`` で時間を進めます。

```swift
let tester = SagaTester(initialState: AppState(), reduce: appReducer.reduce, saga: saga)
await tester.send(.fetch(1))
try tester.receive(.fetched(User(id: 1)))
try await tester.finish()
```

## Topics

- ``SagaTester``
- ``TestClock``
- ``SagaTesterFailure``
