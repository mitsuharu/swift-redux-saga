# ``Saga``

構造化並行性で実装した Redux Saga。Redux の具体型には依存しません。

## Overview

Saga は ``SagaContext`` を受け取る async 関数です。redux-saga のジェネレーター関数の `yield` の代わりに、コンテキストの Effect を `await` で呼びます。

```swift
let saga = Saga<AppState, AppAction>("user") { ctx in
  ctx.takeLatest(.case { if case .fetch(let id) = $0 { id } else { nil } }) { ctx, id in
    let user = try await ctx.call(fetchUser.execute, id)
    await ctx.put(.fetched(user))
  }
}
```

`fork` した子は親のタスクの子タスクになり、親のキャンセルは子に、子の失敗は親に伝わります。

状態管理とは ``SagaHost`` プロトコル越しにつながります。Redux の Store で使う場合は `ReduxSaga` モジュールの `SagaMiddleware` を使ってください。

Swift にはジェネレーターがないため、redux-saga の「Effect を 1 ステップずつ検証する」テストは書けません。`SagaTesting` モジュールで結果を検証します。

## Topics

### Saga

- ``Saga``
- ``SagaContext``
- ``SagaTask``

### Action のマッチング

- ``ActionPattern``

### チャネル

- ``SagaChannel``
- ``ChannelBuffer``

### ランタイム

- ``SagaRuntime``
- ``SagaHost``

### エラーとモニタ

- ``SagaError``
- ``SagaMonitor``
- ``SagaID``
- ``SagaResult``
- ``SagaEffect``
