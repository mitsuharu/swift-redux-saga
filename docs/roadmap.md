# ロードマップ

[設計書](design.md)に沿って、1 PR = 1 目的で進めます。PR の順序は目安で、前後することがあります。完了した PR にはリンクを付けます。

ブランチ名の接頭辞: `feature/` `fix/` `docs/` `ci/` `refactor/`

## M0: 設計と計画

| # | ブランチ | 内容 |
| --- | --- | --- |
| 0-1 | `docs/design` | 設計書、ロードマップ、AGENTS.md、CI ワークフロー（**作者のレビュー・承認後にマージ**） |

## M1: Redux コア

| # | ブランチ | 内容 |
| --- | --- | --- |
| 1-1 | `feature/package-layout` | Package.swift を設計のターゲット構成に更新（tools 6.2、空のターゲットとテストターゲット） （[#2](https://github.com/mitsuharu/swift-redux-saga/pull/2)） |
| 1-2 | `feature/reducer` | `Reducer`、`combine`、`scope`、`ReducerBuilder` + テスト （[#3](https://github.com/mitsuharu/swift-redux-saga/pull/3)） |
| 1-3 | `feature/store` | `@MainActor @Observable Store`、`dispatch`、再入検出 + テスト （[#4](https://github.com/mitsuharu/swift-redux-saga/pull/4)） |
| 1-4 | `feature/middleware` | `Middleware` プロトコル、`MiddlewareAPI`、ミドルウェアチェーン + テスト （[#5](https://github.com/mitsuharu/swift-redux-saga/pull/5)） |
| 1-5 | `feature/keypath-observation` | キーパス単位の Observation 追跡（設計書 5.4）+ テスト （[#6](https://github.com/mitsuharu/swift-redux-saga/pull/6)） |
| 1-6 | `feature/store-observe` | OS に依存しない購読 API（`observe` / `values`）+ テスト （[#7](https://github.com/mitsuharu/swift-redux-saga/pull/7)） |
| 1-7 | `feature/default-isolation-tests` | default MainActor isolation を有効にしたテストターゲット （[#8](https://github.com/mitsuharu/swift-redux-saga/pull/8)） |

## M2: Saga コア

| # | ブランチ | 内容 |
| --- | --- | --- |
| 2-1 | `feature/locked` | 内部の排他制御 `Locked<Value>`（Darwin / Linux）+ テスト （[#9](https://github.com/mitsuharu/swift-redux-saga/pull/9)） |
| 2-2 | `feature/action-pattern` | `ActionPattern`（型による判定、パターンマッチ）+ テスト （[#11](https://github.com/mitsuharu/swift-redux-saga/pull/11)） |
| 2-3 | `feature/saga-runtime` | `SagaHost`、`SagaRuntime`、`ActionMulticaster`、`Saga` / `SagaContext` / `SagaTask`、`take` / `put` / `select` / `call` / `join` + テスト（骨格だけではテストできないため 2-4 と統合） （[#12](https://github.com/mitsuharu/swift-redux-saga/pull/12)） |
| 2-5 | `feature/saga-fork` | `fork` / `spawn` / `SagaTask.cancel` / `join` / `isCancelled`、キャンセル伝播 + テスト （[#13](https://github.com/mitsuharu/swift-redux-saga/pull/13)） |
| 2-6 | `feature/saga-errors` | エラー伝播、`onError`、`SagaMonitor` + テスト （[#14](https://github.com/mitsuharu/swift-redux-saga/pull/14)） |
| 2-7 | `feature/saga-testing` | `SagaTesting`: `TestClock`、`SagaTester`、`settle()`、`delay`（3-1 を統合）+ テスト （[#15](https://github.com/mitsuharu/swift-redux-saga/pull/15)） |
| 2-8 | `feature/saga-middleware` | `ReduxSaga`: `SagaMiddleware`、Host の実装 + テスト （[#16](https://github.com/mitsuharu/swift-redux-saga/pull/16)） |

## M3: Saga ヘルパー

| # | ブランチ | 内容 |
| --- | --- | --- |
| 3-1 | `feature/saga-delay` | `delay`（Clock 注入）+ テスト → 2-7 に統合 |
| 3-2 | `feature/saga-take-helpers` | `takeEvery` / `takeLatest` / `takeLeading` + テスト （[#17](https://github.com/mitsuharu/swift-redux-saga/pull/17)） |
| 3-3 | `feature/saga-debounce-throttle` | `debounce` / `throttle` + テスト （[#18](https://github.com/mitsuharu/swift-redux-saga/pull/18)） |
| 3-4 | `feature/saga-all-race` | `all` / `race`（敗者のキャンセル）+ テスト （[#19](https://github.com/mitsuharu/swift-redux-saga/pull/19)） |

## M4: Saga チャネル

| # | ブランチ | 内容 |
| --- | --- | --- |
| 4-1 | `feature/saga-channels` | `SagaChannel`、`actionChannel`（バッファ方式の指定）、`eventChannel`（購読関数版、AsyncSequence 版）+ テスト（4-2 を統合） （[#20](https://github.com/mitsuharu/swift-redux-saga/pull/20)） |

## M5: Redux Toolkit 相当

| # | ブランチ | 内容 |
| --- | --- | --- |
| 5-1 | `feature/slice` | `Slice` プロトコル + テスト （[#22](https://github.com/mitsuharu/swift-redux-saga/pull/22)） |
| 5-2 | `feature/store-builder` | `configureStore` 相当の result builder 初期化子 + テスト （[#23](https://github.com/mitsuharu/swift-redux-saga/pull/23)） |
| 5-3 | `feature/selector` | `createSelector`（メモ化）+ テスト （[#24](https://github.com/mitsuharu/swift-redux-saga/pull/24)） |
| 5-4 | `feature/entity-adapter` | `EntityState` / `EntityAdapter` + テスト （[#25](https://github.com/mitsuharu/swift-redux-saga/pull/25)） |
| 5-5 | `feature/test-store` | `ReduxTesting`: `TestStore` + テスト （[#26](https://github.com/mitsuharu/swift-redux-saga/pull/26)） |

## M6: SwiftUI / UIKit 連携

| # | ブランチ | 内容 |
| --- | --- | --- |
| 6-1 | `feature/swiftui-helpers` | `ReduxSwiftUI`: Environment、`binding` + テスト （[#27](https://github.com/mitsuharu/swift-redux-saga/pull/27)） |
| 6-2 | `feature/uikit-helpers` | `ReduxUIKit`: 購読トークンの寿命管理など + テスト （[#28](https://github.com/mitsuharu/swift-redux-saga/pull/28)） |
| 6-3 | `ci/ios-simulator-tests` | CI に iOS シミュレータでのテストを追加（必要なら） |

## M7: Example

| # | ブランチ | 内容 |
| --- | --- | --- |
| 7-1 | `feature/example-domain` | `Examples/` のローカルパッケージ（`Domain` / `AppFeature`）+ テスト （[#29](https://github.com/mitsuharu/swift-redux-saga/pull/29)） |
| 7-2 | `feature/example-swiftui` | SwiftUI / UIKit サンプルアプリ（`Examples.xcodeproj`）と CI でのビルド（7-3、7-4 を統合） （[#30](https://github.com/mitsuharu/swift-redux-saga/pull/30)） |

## M8: マクロ

| # | ブランチ | 内容 |
| --- | --- | --- |
| 8-1 | `feature/macros` | `ReduxMacros`（swift-syntax）、`@ActionCases`、`@Slice`、キーパス版の `ActionPattern.case` / `Reducer.scope` / `slice` + テスト、Example への適用（8-2、8-3 を統合） （[#32](https://github.com/mitsuharu/swift-redux-saga/pull/32)） |

## M9: ドキュメント整備

| # | ブランチ | 内容 |
| --- | --- | --- |
| 9-1 | `docs/readme` | README（使い方、redux-saga とのテスト方法の違い、default isolation の注意）、DocC カタログ、ReSwift-Saga からの移行ガイド（9-2、9-3 を統合） （[#31](https://github.com/mitsuharu/swift-redux-saga/pull/31)） |

## M10: 追加の機能

| # | ブランチ | 内容 |
| --- | --- | --- |
| 10-1 | `feature/binding-action` | 入力欄の Binding（`BindableState` / `BindingAction` / `BindableAction`） （[#35](https://github.com/mitsuharu/swift-redux-saga/pull/35)） |
| 10-2 | `feature/nested-observation` | ネストしたプロパティ単位の Observation 追跡（マクロ） （[#37](https://github.com/mitsuharu/swift-redux-saga/pull/37)） |
| 10-3 | `feature/logging-middleware` | `LoggingMiddleware`（os.Logger、デバッグビルドのみ） （[#43](https://github.com/mitsuharu/swift-redux-saga/pull/43)） |
| 10-4 | `feature/persistence` | State の永続化（`ReduxPersistence`） （[#44](https://github.com/mitsuharu/swift-redux-saga/pull/44)） |
| 10-5 | `feature/example-mvvm` | Example を MVVM と併用する形にする、`ObservationToken.observe` （[#45](https://github.com/mitsuharu/swift-redux-saga/pull/45)） |

## M11: 0.1.0 に向けた見直し

| # | ブランチ | 内容 |
| --- | --- | --- |
| 11-1 | `fix/channel-multiple-takers` | `SagaChannel` を複数の Saga で読むと固まる不具合 （[#38](https://github.com/mitsuharu/swift-redux-saga/pull/38)） |
| 11-2 | `fix/tracked-state-untracked-properties` | `@TrackedState` で追跡できないプロパティの通知漏れ （[#39](https://github.com/mitsuharu/swift-redux-saga/pull/39)） |
| 11-3 | `fix/production-safety` | Activity の不整合で落ちない、エラーログのプライバシー （[#40](https://github.com/mitsuharu/swift-redux-saga/pull/40)） |
| 11-4 | `ci/other-platforms` | tvOS / watchOS / visionOS のビルドを CI に追加 （[#41](https://github.com/mitsuharu/swift-redux-saga/pull/41)） |
| 11-5 | `refactor/shared-advance` | 時計を進める処理を `TestClock` にまとめる （[#42](https://github.com/mitsuharu/swift-redux-saga/pull/42)） |
| 11-6 | `docs/review` | ドキュメントの見直し、プロダクトを用途ごとに使えるようにする （[#46](https://github.com/mitsuharu/swift-redux-saga/pull/46)） |
| 11-8 | `feature/example-direct-store` | Example に Store を直接使う画面を追加し、MVVM 経由と並べる （[#47](https://github.com/mitsuharu/swift-redux-saga/pull/47)） |
| 11-7 | `docs/release-0.1.0` | 0.1.0 のリリース（CHANGELOG、README のインストール手順） |

## M12: 実用面の見直し

| # | ブランチ | 内容 |
| --- | --- | --- |
| 12-1 | `test/memory-leaks` | メモリリークのテスト、`SagaTester` の循環参照の修正 （[#50](https://github.com/mitsuharu/swift-redux-saga/pull/50)） |
| 12-2 | `fix/wait-until-idle-real-clock` | 実時間の `delay` の間も `waitUntilIdle()` が戻る （[#52](https://github.com/mitsuharu/swift-redux-saga/pull/52)） |
| 12-3 | `fix/persistence-save-order` | 永続化の保存の順序、バックグラウンドに入るときの保存 （[#53](https://github.com/mitsuharu/swift-redux-saga/pull/53)、[#57](https://github.com/mitsuharu/swift-redux-saga/pull/57)） |
| 12-4 | `fix/startup-actions` | 起動直後に dispatch した Action を、Saga が動き出すまで溜めて届ける （[#54](https://github.com/mitsuharu/swift-redux-saga/pull/54)） |
| 12-5 | `docs/saga-error-handling` | README に Saga のエラー処理の節 （[#55](https://github.com/mitsuharu/swift-redux-saga/pull/55)） |
| 12-6 | `fix/saga-cancellation-and-errors` | `call` のキャンセル後の結果とエラー、`all` / `race` のエラーとキャンセル、`eventChannel` のエラー （[#56](https://github.com/mitsuharu/swift-redux-saga/pull/56)、[#59](https://github.com/mitsuharu/swift-redux-saga/pull/59)） |
| 12-7 | `fix/observation-token-and-entity-id` | 購読の解除でハンドラを手放す、エンティティの ID の重複 （[#58](https://github.com/mitsuharu/swift-redux-saga/pull/58)） |
| 12-8 | `fix/example-sequential-edits` | Example で、保存中の連続操作で変更を失わない （[#60](https://github.com/mitsuharu/swift-redux-saga/pull/60)） |
| 12-9 | `feature/identified-access` | 一覧の要素を ID で読み書きする添字、Optional の値の Binding （[#61](https://github.com/mitsuharu/swift-redux-saga/pull/61)） |
| 12-10 | `feature/testing-overlapping-requests` | テストで待たずに送る `dispatch` と、届くまで待つ `receive(_:timeout:)` （[#62](https://github.com/mitsuharu/swift-redux-saga/pull/62)） |
| 12-11 | `feature/saga-scope` | 子の Saga を子の型のまま親に接続する （[#63](https://github.com/mitsuharu/swift-redux-saga/pull/63)） |
| 12-12 | `feature/example-auth` | Example をログインと ToDo の 2 機能の構成に、Saga の寿命のガイド （[#64](https://github.com/mitsuharu/swift-redux-saga/pull/64)） |
| 12-13 | `docs/consistency-review` | ドキュメントの食い違いの修正、default MainActor isolation の書き方 （[#65](https://github.com/mitsuharu/swift-redux-saga/pull/65)） |
| 12-14 | `fix/test-clock-delay-race` | `TestClock` で `delay` する Saga がまれに起こされない競合 （[#66](https://github.com/mitsuharu/swift-redux-saga/pull/66)） |
| 12-15 | `feature/store-scope` | State と Action の一部だけを扱う Store（`Store.scope`） （[#67](https://github.com/mitsuharu/swift-redux-saga/pull/67)） |
| 12-16 | `refactor/remove-waste` | ムダの整理（重複した関数、Example の組み立て、CI、CHANGELOG） （[#68](https://github.com/mitsuharu/swift-redux-saga/pull/68)） |
| 12-17 | `fix/store-scope-reentrancy` | 子 Store の通知中の `scope` で停止する問題、通知したキーパスを追跡の表から外す （[#69](https://github.com/mitsuharu/swift-redux-saga/pull/69)） |
| 12-18 | `refactor/saga-scope-single-runtime` | Saga の scope を、ランタイムを分けずに型だけ付け替える方式にする （[#70](https://github.com/mitsuharu/swift-redux-saga/pull/70)） |
| 12-19 | `fix/example-stale-results` | Example で、ログアウト前や読み込み中の古い結果が State に入らない （[#71](https://github.com/mitsuharu/swift-redux-saga/pull/71)） |
| 12-20 | `fix/event-channel-cancellation` | `eventChannel` の入力が `CancellationError` で終わってもチャネルを閉じる （[#72](https://github.com/mitsuharu/swift-redux-saga/pull/72)） |
| 12-21 | `ci/minimum-swift` | 最低対応の Swift 6.2 でも Linux でビルドとテスト （[#73](https://github.com/mitsuharu/swift-redux-saga/pull/73)） |
| 12-22 | `fix/review-runtime-lifecycles` | チャネルのキャンセル時に、ほかの受信者向けの値と終了理由を保つ （[#77](https://github.com/mitsuharu/swift-redux-saga/pull/77)） |
| 12-23 | `fix/take-leading-startup` | takeLeading の登録直後の最初の Action を保ち、実行中の追加の Action は捨てる （[#78](https://github.com/mitsuharu/swift-redux-saga/pull/78)） |
| 12-24 | `fix/deterministic-test-waits` | 購読の再登録を通知で待ち、AsyncSequence の終了テストに待機上限を設ける （[#79](https://github.com/mitsuharu/swift-redux-saga/pull/79)） |
| 12-25 | `fix/example-refresh-control-lifetime` | UIKit Example の更新コントロールが自分自身を保持する循環参照を解消する （[#80](https://github.com/mitsuharu/swift-redux-saga/pull/80)） |
| 12-26 | `fix/persistence-operation-order` | 削除を保存と同じ順序に並べ、削除待ちの間に予約された新しい保存を失わない （[#82](https://github.com/mitsuharu/swift-redux-saga/pull/82)） |
| 12-27 | `fix/example-auth-event-gap` | Example で認証 State の読み取り中に届いた再ログインを取りこぼさない （[#84](https://github.com/mitsuharu/swift-redux-saga/pull/84)） |
| 12-28 | `ci/release-workflow` | タグの push か手動実行で、タグと GitHub Release を作るワークフロー |
