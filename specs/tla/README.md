# TLA+ による仕様

並行に動く部分の「どの割り込み順でも成り立つべき性質」を TLA+ で書き、モデル検査器 TLC で調べます。
Swift のテストは実際に起きた 1 つの順序しか確かめられませんが、TLC は小さな範囲（操作の回数などの上限）であり得る順序をすべて調べます。

## PersistenceMiddleware.tla

`PersistenceMiddleware`（`Sources/ReduxPersistence/PersistenceMiddleware.swift`）の保存・削除の順序のモデルです。
メインアクター上の操作（State の変化、`flush()`、`clear()`）と、それぞれが作る `Task.detached` の進み方（debounce の待ち、前の保存の待ち、置き換えの確認、書き込み）を状態遷移として書いています。

調べる性質は次の 4 つです。

- `WritesInOrder`: ストレージへの書き込みは操作の発行順に起こり、古い State や古い削除が新しい結果を上書きしない。
- `ConsistentWhenIdle`: タスクがすべて終わったら、ストレージは最後の操作の結果と一致する（`clear()` の後に保存が戻らず、最後の State が保存されている）。
- `WaitersSeeTheirOp`: `flush()` と `clear()` が戻った時点で、呼んだ時点の最後の操作がストレージに反映されている。
- `EventuallyIdle`: 待ちが循環せず、タスクは必ず終わる。

モデルにしていないこともあります。保存・削除の失敗（`onError` に渡すだけで、順序には影響しない）、debounce の長さ（時間が経つことを「いつでも起こり得る」として扱う）、`hasChanged` による保存の要否の判定（変化があった場合だけを Change として扱う）です。

設定ファイルは 3 つあります。`PersistenceMiddleware.cfg` は実装どおりの設定で、すべての性質が成り立つことを確かめます。
残りの 2 つは過去に直した不具合を再現する設定で、TLC が反例を見つけることを確かめます（モデルが性質を検査できていることの確認）。

| 設定 | 内容 | 期待する結果 |
| --- | --- | --- |
| `PersistenceMiddleware.cfg` | 実装どおり | 違反なし |
| `PersistenceMiddleware_ClearNotChained.cfg` | `clear()` が後続の保存を待たせない | 違反あり |
| `PersistenceMiddleware_SaveNotSerialized.cfg` | 保存が前の保存・削除を待たない | 違反あり |

## Channel.tla

Saga のチャネル（`Sources/Saga/Internal/ChannelCore.swift`）の `put` / `take` / `close` と、受け取り側のキャンセルのモデルです。バッファの方式は上限なし（`.unbounded`）を扱います。
複数の受け取り側（ワーカー）が `take` を繰り返し、送り手が値を入れ、どこかで `close` され、受け取り側のタスクはいつでもキャンセルされ得る、という状況のあらゆる割り込み順を調べます。
実装はロックの中で待っている continuation を取り出し、ロックの外で resume するので、モデルでもこの 2 つを別の手順にして、間に割り込めるようにしています。

調べる性質は次の 6 つです。

- `NoDoubleResume`: 1 つの continuation を 2 回 resume しない。
- `NoLossInOrder`: 閉じる前に入れた値は、失われず、重複せず、入れた順に受け取り側へ渡る。
- `ErrorAtMostOnce`: `close(throwing:)` に渡したエラーは高々 1 回だけ投げる。
- `CancelledTakeConsumesNothing`: キャンセル済みのタスクの `take` は、値も終了理由も消費しない（`SagaChannel.take()` のドキュメントの約束）。
- `NoTakerLeftWaiting`: 閉じたら、待っている受け取り側は必ず戻る。
- `CancelledTakerReturns`: キャンセルされた受け取り側は必ず `take` から戻る。

待っている間にキャンセルされた受け取り側に、送り手が先に値を渡すことはあります（そのときは `CancellationError` ではなく値が返ります）。値は失われないので、性質としては許しています。
モデルにしていないことは、上限のあるバッファ（`.newest` / `.oldest`。値を捨てるのが仕様）、`onClose` のハンドラ、`Activity` による待ちの数え方です。

| 設定 | 内容 | 期待する結果 |
| --- | --- | --- |
| `Channel.cfg` | 実装どおり（`close` にエラーを渡さない） | 違反なし |
| `Channel_CloseWithError.cfg` | 実装どおり（`close` にエラーを渡す） | 違反なし |
| `Channel_NoCancelGuard.cfg` | `take` のロックの中で `Task.isCancelled` を確かめない | 違反あり |
| `Channel_FailureNotCleared.cfg` | 終了理由のエラーを投げた後も消さない | 違反あり |

`Channel_NoCancelGuard.cfg` の反例は、`onCancel` が待機の登録より先に走って何も外せず、その後に登録した受け取り側が二度と戻らない、というものです（性質を `CancelledTakerReturns` だけにすると、この反例が出ます）。

## 実行のしかた

Java 11 以降と [tla2tools.jar](https://github.com/tlaplus/tlaplus/releases)（CI と同じ v1.7.4）が要ります。
`check.sh` は、実装どおりの設定に違反がないことと、不具合を再現する設定に違反が見つかることをまとめて確かめます。
PR では `.github/workflows/tla.yml` が同じスクリプトを実行します。

```sh
specs/tla/check.sh path/to/tla2tools.jar
```

1 つの設定だけを調べ、反例の手順を読みたいときは TLC を直接実行します。

```sh
cd specs/tla
java -XX:+UseParallelGC -cp path/to/tla2tools.jar tlc2.TLC -workers auto -cleanup \
  -config PersistenceMiddleware_ClearNotChained.cfg PersistenceMiddleware.tla
```

## 実装を変えたとき

モデルは実装を手で写したものなので、実装と自動では連動しません。
`PersistenceMiddleware` の `schedule` / `flush()` / `clear()` の待ち方や、`ChannelCore` のロックの中の処理と resume の順序を変えたら、同じ PR でモデルも直し、TLC で確かめてください。
モデルを足したら、`check.sh` の表と `.github/workflows/tla.yml` の `paths` に、設定とモデル化した実装のファイルを足してください。
