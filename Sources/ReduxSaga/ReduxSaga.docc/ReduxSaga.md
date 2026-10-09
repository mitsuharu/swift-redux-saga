# ``ReduxSaga``

Redux の Store に Saga を載せるミドルウェア。

## Overview

```swift
let sagaMiddleware = SagaMiddleware<AppState, AppAction>()
let store = Store(initialState: AppState(), reducer: appReducer, middleware: [sagaMiddleware])
sagaMiddleware.run(appSagas.root)
```

Saga が受け取るのは、reducer を適用した後の Action です。`run` の直後に dispatch した Action は、起動した Saga が最初の Effect に達するまで溜めて後から届けるので、取りこぼしません。

## Topics

- ``SagaMiddleware``
