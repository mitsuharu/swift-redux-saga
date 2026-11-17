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

設定ファイルは 3 つあります。`PersistenceMiddleware.cfg` は実装どおりの設定で、すべての性質が成り立つことを確かめます。
残りの 2 つは過去に直した不具合を再現する設定で、TLC が反例を見つけることを確かめます（モデルが性質を検査できていることの確認）。

| 設定 | 内容 | 期待する結果 |
| --- | --- | --- |
| `PersistenceMiddleware.cfg` | 実装どおり | 違反なし |
| `PersistenceMiddleware_ClearNotChained.cfg` | `clear()` が後続の保存を待たせない | 違反あり |
| `PersistenceMiddleware_SaveNotSerialized.cfg` | 保存が前の保存・削除を待たない | 違反あり |

## 実行のしかた

Java 11 以降と [tla2tools.jar](https://github.com/tlaplus/tlaplus/releases) が要ります。

```sh
cd specs/tla
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto -cleanup \
  -config PersistenceMiddleware.cfg PersistenceMiddleware.tla
```

## 実装を変えたとき

モデルは実装を手で写したものなので、実装と自動では連動しません。
`PersistenceMiddleware` の `schedule` / `flush()` / `clear()` の待ち方を変えたら、同じ PR でモデルも直し、TLC で確かめてください。
