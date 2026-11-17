-------------------------------- MODULE Channel --------------------------------
(***************************************************************************)
(* チャネル（Sources/Saga/Internal/ChannelCore.swift）の put / take /       *)
(* close とキャンセルのモデル。バッファの方式は上限なし（.unbounded）。     *)
(*                                                                         *)
(* 複数の受け取り側（Saga）がそれぞれ take を繰り返し、送り手が値を put し、 *)
(* どこかで close される。受け取り側のタスクはいつでもキャンセルされ得る。 *)
(*                                                                         *)
(* 実装では、ロックの中で待っている continuation を取り出し、ロックの外で   *)
(* resume する。この 2 つの間にほかの処理が割り込めるように、               *)
(* 取り出し（slot に結果を置く）と resume（Resume）を別の手順にしている。   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Takers,         \* 受け取り側（Saga）の集合
    NumPuts,        \* put する値の数（値は 1..NumPuts を順に送る）
    MaxTakes,       \* 1 つの受け取り側が値を受け取る回数の上限
    CloseWithError, \* close(throwing:) にエラーを渡すか
    CancelGuard,    \* take のロックの中で Task.isCancelled を確かめるか（実装は TRUE）
    ClearFailure    \* 終了理由のエラーを 1 回投げたら消すか（実装は TRUE）

None == [kind |-> "none"]

VARIABLES
    buffer,     \* 溜まっている値
    waiting,    \* 待っている受け取り側（待ち始めた順）。実装の takers
    closed,     \* 実装の isClosed
    failure,    \* 実装の failure（まだ誰にも投げていない終了理由のエラーがあるか）
    nextPut,    \* 次に put する値
    accepted,   \* 閉じる前に put された値の列
    received,   \* 受け取り側に渡した値の列（渡した順）
    errors,     \* 終了理由のエラーを投げた回数
    pc,         \* 受け取り側ごとの状態
    taken,      \* 受け取り側ごとの、値を受け取った回数
    cancelled,  \* 受け取り側のタスクがキャンセルされたか（Task.isCancelled）
    handler,    \* onCancel のハンドラをまだ実行していない take があるか
    cancelledAtEntry, \* take を始めた時点でキャンセル済みだったか
    slot,       \* ロックの中で取り出され、まだ resume されていない結果
    doubleResume \* 同じ continuation を 2 回 resume しようとしたか

vars == <<buffer, waiting, closed, failure, nextPut, accepted, received, errors,
          pc, taken, cancelled, handler, cancelledAtEntry, slot, doubleResume>>

Range(s) == {s[i] : i \in 1..Len(s)}

Remove(s, t) == SelectSeq(s, LAMBDA x : x # t)

\* 取り出した continuation に渡す結果を置く（resume はロックの外で、別の手順で行う）。
Hand(sl, t, r) == [sl EXCEPT ![t] = r]
HandCheck(t) == slot[t] # None

Init ==
    /\ buffer = <<>>
    /\ waiting = <<>>
    /\ closed = FALSE
    /\ failure = FALSE
    /\ nextPut = 1
    /\ accepted = <<>>
    /\ received = <<>>
    /\ errors = 0
    /\ pc = [t \in Takers |-> "idle"]
    /\ taken = [t \in Takers |-> 0]
    /\ cancelled = [t \in Takers |-> FALSE]
    /\ handler = [t \in Takers |-> FALSE]
    /\ cancelledAtEntry = [t \in Takers |-> FALSE]
    /\ slot = [t \in Takers |-> None]
    /\ doubleResume = FALSE

(* ---- 送り手 ---- *)

\* put(_:): 閉じていれば捨てる。待っている受け取り側がいれば先頭に渡し、いなければ溜める。
Put ==
    /\ nextPut <= NumPuts
    /\ nextPut' = nextPut + 1
    /\ IF closed
         THEN UNCHANGED <<buffer, waiting, accepted, received, slot, doubleResume>>
       ELSE IF waiting # <<>>
         THEN LET t == Head(waiting) IN
              /\ waiting' = Tail(waiting)
              /\ doubleResume' = (doubleResume \/ HandCheck(t))
              /\ slot' = Hand(slot, t, [kind |-> "value", v |-> nextPut])
              /\ accepted' = Append(accepted, nextPut)
              /\ received' = Append(received, nextPut)
              /\ UNCHANGED buffer
         ELSE /\ buffer' = Append(buffer, nextPut)
              /\ accepted' = Append(accepted, nextPut)
              /\ UNCHANGED <<waiting, received, slot, doubleResume>>
    /\ UNCHANGED <<closed, failure, errors, pc, taken, cancelled, handler, cancelledAtEntry>>

\* close(throwing:): 待っている受け取り側には nil を渡す。エラーがあれば、待っている先頭に投げるか、後の take のために残す。
Close ==
    /\ ~closed
    /\ closed' = TRUE
    /\ waiting' = <<>>
    /\ LET errTo == IF CloseWithError /\ waiting # <<>> THEN {Head(waiting)} ELSE {}
       IN /\ slot' = [t \in Takers |->
                        IF t \in errTo THEN [kind |-> "error"]
                        ELSE IF t \in Range(waiting) THEN [kind |-> "nil"]
                        ELSE slot[t]]
          /\ doubleResume' = (doubleResume \/ \E t \in Range(waiting) : HandCheck(t))
          /\ errors' = errors + Cardinality(errTo)
          /\ failure' = (CloseWithError /\ waiting = <<>>)
    /\ UNCHANGED <<buffer, nextPut, accepted, received, pc, taken, cancelled, handler, cancelledAtEntry>>

(* ---- 受け取り側 ---- *)

\* take() を呼ぶ（withTaskCancellationHandler に入る）。
Begin(t) ==
    /\ pc[t] = "idle"
    /\ taken[t] < MaxTakes
    /\ pc' = [pc EXCEPT ![t] = "entered"]
    \* すでにキャンセル済みなら、onCancel はこの take のために（いつか）1 回実行される。
    /\ handler' = [handler EXCEPT ![t] = cancelled[t]]
    /\ cancelledAtEntry' = [cancelledAtEntry EXCEPT ![t] = cancelled[t]]
    /\ UNCHANGED <<buffer, waiting, closed, failure, nextPut, accepted, received, errors,
                   taken, cancelled, slot, doubleResume>>

\* withCheckedThrowingContinuation の中のロック区間。すぐ結果が出れば、その場で resume して戻る。
Enter(t) ==
    /\ pc[t] = "entered"
    /\ IF CancelGuard /\ cancelled[t]
         THEN /\ pc' = [pc EXCEPT ![t] = "cancelled"]
              /\ UNCHANGED <<buffer, waiting, failure, received, errors, taken>>
       ELSE IF buffer # <<>>
         THEN /\ received' = Append(received, Head(buffer))
              /\ buffer' = Tail(buffer)
              /\ pc' = [pc EXCEPT ![t] = "idle"]
              /\ taken' = [taken EXCEPT ![t] = @ + 1]
              /\ UNCHANGED <<waiting, failure, errors>>
       ELSE IF closed
         THEN IF failure
                THEN /\ failure' = ~ClearFailure
                     /\ errors' = errors + 1
                     /\ pc' = [pc EXCEPT ![t] = "failed"]
                     /\ UNCHANGED <<buffer, waiting, received, taken>>
                ELSE /\ pc' = [pc EXCEPT ![t] = "finished"]
                     /\ UNCHANGED <<buffer, waiting, failure, received, errors, taken>>
       ELSE /\ waiting' = Append(waiting, t)
            /\ pc' = [pc EXCEPT ![t] = "waiting"]
            /\ UNCHANGED <<buffer, failure, received, errors, taken>>
    /\ UNCHANGED <<closed, nextPut, accepted, cancelled, handler, cancelledAtEntry, slot, doubleResume>>

\* 取り出された continuation が resume され、take が戻る。
Resume(t) ==
    /\ pc[t] = "waiting"
    /\ slot[t] # None
    /\ pc' = [pc EXCEPT ![t] =
                CASE slot[t].kind = "value"  -> "idle"
                  [] slot[t].kind = "nil"    -> "finished"
                  [] slot[t].kind = "error"  -> "failed"
                  [] slot[t].kind = "cancel" -> "cancelled"]
    /\ taken' = [taken EXCEPT ![t] = IF slot[t].kind = "value" THEN @ + 1 ELSE @]
    /\ slot' = [slot EXCEPT ![t] = None]
    /\ UNCHANGED <<buffer, waiting, closed, failure, nextPut, accepted, received, errors,
                   cancelled, handler, cancelledAtEntry, doubleResume>>

\* タスクのキャンセル。Task.isCancelled が立ち、take の中なら onCancel が（いつか）実行される。
Cancel(t) ==
    /\ ~cancelled[t]
    /\ pc[t] \notin {"finished", "failed", "cancelled"}
    /\ cancelled' = [cancelled EXCEPT ![t] = TRUE]
    /\ handler' = [handler EXCEPT ![t] = pc[t] \in {"entered", "waiting"}]
    /\ UNCHANGED <<buffer, waiting, closed, failure, nextPut, accepted, received, errors,
                   pc, taken, cancelledAtEntry, slot, doubleResume>>

\* onCancel: 自分が待っていれば、自分の待機だけを外して CancellationError を渡す。
OnCancel(t) ==
    /\ handler[t]
    /\ handler' = [handler EXCEPT ![t] = FALSE]
    /\ IF t \in Range(waiting)
         THEN /\ waiting' = Remove(waiting, t)
              /\ doubleResume' = (doubleResume \/ HandCheck(t))
              /\ slot' = Hand(slot, t, [kind |-> "cancel"])
         ELSE UNCHANGED <<waiting, slot, doubleResume>>
    /\ UNCHANGED <<buffer, closed, failure, nextPut, accepted, received, errors,
                   pc, taken, cancelled, cancelledAtEntry>>

TakerStep(t) == Begin(t) \/ Enter(t) \/ Resume(t) \/ OnCancel(t)

Done(t) == pc[t] \in {"finished", "failed", "cancelled"}
           \/ (pc[t] = "idle" /\ taken[t] = MaxTakes)

Terminated ==
    /\ nextPut > NumPuts /\ closed
    /\ \A t \in Takers : Done(t)
    /\ UNCHANGED vars

Next ==
    \/ Put \/ Close
    \/ \E t \in Takers : TakerStep(t) \/ Cancel(t)
    \/ Terminated

\* 受け取り側の手順は止まらずに進む（送り手・close・キャンセルは起きても起きなくてもよい）。
Spec == Init /\ [][Next]_vars /\ \A t \in Takers : WF_vars(TakerStep(t))

(* ---- 検査する性質 ---- *)

\* 1 つの continuation を 2 回 resume しない（CheckedContinuation ならクラッシュする）。
NoDoubleResume == ~doubleResume

\* 閉じる前に put された値は、失われず、重複せず、put した順に受け取り側へ渡る（残りはバッファにある）。
NoLossInOrder == received \o buffer = accepted

\* 終了理由のエラーは高々 1 回だけ投げる。
ErrorAtMostOnce == errors <= 1

\* take を始めた時点でキャンセル済みなら、値も終了理由も消費せずに CancellationError で戻る。
CancelledTakeConsumesNothing ==
    \A t \in Takers : cancelledAtEntry[t] => pc[t] \notin {"idle", "finished", "failed"}

\* 閉じたら、待っている受け取り側はいつか必ず戻る（取り残されない）。
NoTakerLeftWaiting ==
    \A t \in Takers : (closed /\ pc[t] = "waiting") ~> (pc[t] # "waiting")

\* キャンセルされた受け取り側は、いつか必ず take から戻る。
CancelledTakerReturns ==
    \A t \in Takers : (cancelled[t] /\ pc[t] = "waiting") ~> (pc[t] # "waiting")
=============================================================================
