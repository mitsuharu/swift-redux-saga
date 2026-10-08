# ``ReduxSaga``

Redux の Store に Saga を載せるミドルウェア。

## Overview

```swift
let sagaMiddleware = SagaMiddleware<AppState, AppAction>()
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [sagaMiddleware])
sagaMiddleware.run(appSagas.root)
```

Saga が受け取るのは、reducer を適用した後の Action です。`run` の直後に dispatch した Action は、まだ待ち始めていない Saga に届かないことがあるため、起動時の処理はルート Saga の中に書くか、``SagaMiddleware/waitUntilIdle()`` で待ってください。

## Topics

- ``SagaMiddleware``
