#!/usr/bin/env bash
# specs/tla のモデルを TLC で検査する。
#
# 使い方: specs/tla/check.sh <tla2tools.jar のパス>
#
# 下の表の設定ごとに、実装どおりの設定は違反がないこと、
# 過去の不具合を再現する設定は違反が見つかることを確かめる。
# 後者を検査するのは、モデルや性質を書き換えたときに「何も検出できないモデル」になっていないかを知るため。
set -euo pipefail

jar="${1:?tla2tools.jar のパスを指定してください}"
cd "$(dirname "$0")"

# モジュール 設定 期待（pass = 違反なし / fail = 違反あり）
checks=(
  "PersistenceMiddleware PersistenceMiddleware.cfg pass"
  "PersistenceMiddleware PersistenceMiddleware_ClearNotChained.cfg fail"
  "PersistenceMiddleware PersistenceMiddleware_SaveNotSerialized.cfg fail"
  "Channel Channel.cfg pass"
  "Channel Channel_CloseWithError.cfg pass"
  "Channel Channel_NoCancelGuard.cfg fail"
  "Channel Channel_FailureNotCleared.cfg fail"
  "AllRace All.cfg pass"
  "AllRace Race.cfg pass"
  "AllRace All_NoCancelCheckAtReturn.cfg fail"
  "AllRace Race_NoCancelCheckAtReturn.cfg fail"
  "StoreObservation StoreObservation.cfg pass"
  "StoreObservation StoreObservation_SweepEveryUpdate.cfg pass"
  "StoreObservation StoreObservation_SweepWithoutNotify.cfg fail"
  "StoreObservation StoreObservation_SyncReread.cfg fail"
)

status=0
for entry in "${checks[@]}"; do
  read -r module config expected <<<"$entry"
  log="$(mktemp)"
  metadir="$(mktemp -d)"
  # TLC は違反を見つけると 0 以外で終わる。仕様の誤り（構文やエラー）と区別するため、出力も見る。
  set +e
  java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -cleanup \
    -metadir "$metadir" -config "$config" "$module.tla" >"$log" 2>&1
  code=$?
  set -e
  if [[ $code -eq 0 ]] && grep -q "No error has been found" "$log"; then
    actual=pass
  elif grep -qE "is violated|properties were violated" "$log"; then
    actual=fail
  else
    actual=error
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "ok: $config ($actual)"
  else
    echo "NG: $config (期待 $expected, 結果 $actual)"
    cat "$log"
    status=1
  fi
  rm -rf "$log" "$metadir"
done
exit $status
