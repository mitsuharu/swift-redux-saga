---------------------------- MODULE PersistenceMiddleware ----------------------------
(***************************************************************************)
(* PersistenceMiddleware（Sources/ReduxPersistence/PersistenceMiddleware.swift）*)
(* の保存・削除の順序のモデル。                                            *)
(*                                                                         *)
(* メインアクター上の操作（State の変化 = Change、flush()、clear()）と、     *)
(* それぞれが作る Task.detached（保存タスク・削除タスク）の進み方を、       *)
(* あり得るすべての割り込み順で調べる。                                    *)
(*                                                                         *)
(* 操作には発行順の番号 s を振り、Change / Clear が作るタスクの ID にも     *)
(* その番号を使う（1 つの操作が作るタスクは高々 1 つ）。                   *)
(* ストレージには「最後にどの操作が書いたか」を持たせ、                     *)
(* 古い操作の書き込みが新しい操作の結果を上書きしないことを検査する。       *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    MaxOps,         \* Change と Clear の合計回数の上限
    MaxFlushes,     \* flush() の回数の上限
    SaveWaitsPrev,  \* 保存タスクが前の保存・削除の完了を待つか（実装は TRUE）
    ClearChains     \* clear() が削除タスクを lastSave に置き、後続の保存を待たせるか（実装は TRUE）

Ops == 1..MaxOps
NoTask == 0

VARIABLES
    ops,        \* 発行した Change / Clear の数
    flushes,    \* 呼んだ flush() の数
    intent,     \* 利用者の意図: 最後の操作の結果（data なら保存されているべき、empty なら消えているべき）
    storage,    \* ストレージの中身と、それを書いた操作の番号
    applied,    \* ストレージへの書き込み（保存・削除）を行った操作の番号の列
    tasks,      \* タスク ID -> タスクの状態
    pending,    \* debounce を待っている保存タスク（実装の pending）
    lastSave,   \* 最後に作った保存・削除タスク（実装の lastSave）
    waiters     \* flush() / clear() の呼び出し元: 待っているタスクと、戻った時点で反映されているべき操作

vars == <<ops, flushes, intent, storage, applied, tasks, pending, lastSave, waiters>>

NoRecord == [kind |-> "none", prev |-> NoTask, pc |-> "done", superseded |-> FALSE]

Done(t) == IF t = NoTask THEN TRUE ELSE tasks[t].pc = "done"

LastApplied == IF applied = <<>> THEN 0 ELSE applied[Len(applied)]

\* pending の保存タスクを、新しい操作で置き換えたことにする（isSuperseded = true と cancel()）。
Supersede(ts) ==
    IF pending = NoTask THEN ts
    ELSE [ts EXCEPT ![pending].superseded = TRUE]

Init ==
    /\ ops = 0
    /\ flushes = 0
    /\ intent = [kind |-> "empty", op |-> 0]
    /\ storage = [kind |-> "empty", op |-> 0]
    /\ applied = <<>>
    /\ tasks = [t \in Ops |-> NoRecord]
    /\ pending = NoTask
    /\ lastSave = NoTask
    /\ waiters = {}

(* ---- メインアクター上の操作 ---- *)

\* handle(_:store:next:) で保存する部分が変わった -> schedule(newState)
Change ==
    /\ ops < MaxOps
    /\ LET s == ops + 1 IN
        /\ ops' = s
        /\ tasks' = [Supersede(tasks) EXCEPT ![s] =
                        [kind |-> "save",
                         prev |-> IF SaveWaitsPrev THEN lastSave ELSE NoTask,
                         pc |-> "sleep", superseded |-> FALSE]]
        /\ pending' = s
        /\ lastSave' = s
        /\ intent' = [kind |-> "data", op |-> s]
    /\ UNCHANGED <<flushes, storage, applied, waiters>>

\* clear(): pending を置き換え、前の保存・削除の後に消す。
Clear ==
    /\ ops < MaxOps
    /\ LET s == ops + 1 IN
        /\ ops' = s
        /\ tasks' = [Supersede(tasks) EXCEPT ![s] =
                        [kind |-> "remove", prev |-> lastSave,
                         pc |-> "waitPrev", superseded |-> FALSE]]
        /\ pending' = NoTask
        /\ lastSave' = IF ClearChains THEN s ELSE lastSave
        /\ intent' = [kind |-> "empty", op |-> s]
        \* clear() は削除が終わってから戻る。戻った時点で s 以降の結果になっているべき。
        /\ waiters' = waiters \cup {[on |-> s, target |-> s]}
    /\ UNCHANGED <<flushes, storage, applied>>

\* flush(): pending をキャンセルしてすぐ保存させ（置き換えではない）、lastSave の完了を待つ。
\* キャンセルで sleep が早く終わることは、Wake がいつでも起こり得ることに含まれる。
Flush ==
    /\ flushes < MaxFlushes
    /\ flushes' = flushes + 1
    /\ pending' = NoTask
    /\ waiters' = waiters \cup {[on |-> lastSave, target |-> intent.op]}
    /\ UNCHANGED <<ops, intent, storage, applied, tasks, lastSave>>

(* ---- Task.detached 側の進行 ---- *)

\* clock.sleep(for: debounce) が終わる（時間が経った、またはキャンセルされた）
Wake(t) ==
    /\ tasks[t].pc = "sleep"
    /\ tasks' = [tasks EXCEPT ![t].pc = "waitPrev"]
    /\ UNCHANGED <<ops, flushes, intent, storage, applied, pending, lastSave, waiters>>

\* await previous?.value
AwaitPrev(t) ==
    /\ tasks[t].pc = "waitPrev"
    /\ Done(tasks[t].prev)
    /\ tasks' = [tasks EXCEPT ![t].pc = IF tasks[t].kind = "save" THEN "check" ELSE "write"]
    /\ UNCHANGED <<ops, flushes, intent, storage, applied, pending, lastSave, waiters>>

\* guard !isSuperseded.withLock({ $0 }) else { return }
CheckSuperseded(t) ==
    /\ tasks[t].pc = "check"
    /\ tasks' = [tasks EXCEPT ![t].pc = IF tasks[t].superseded THEN "done" ELSE "write"]
    /\ UNCHANGED <<ops, flushes, intent, storage, applied, pending, lastSave, waiters>>

\* try save(state) / try remove()（ストレージへの 1 回の書き込みは不可分とする）
Write(t) ==
    /\ tasks[t].pc = "write"
    /\ storage' = [kind |-> IF tasks[t].kind = "save" THEN "data" ELSE "empty", op |-> t]
    /\ applied' = Append(applied, t)
    /\ tasks' = [tasks EXCEPT ![t].pc = "done"]
    /\ UNCHANGED <<ops, flushes, intent, pending, lastSave, waiters>>

TaskStep(t) == Wake(t) \/ AwaitPrev(t) \/ CheckSuperseded(t) \/ Write(t)

AllDone == \A t \in Ops : Done(t)

\* 操作を出し尽くし、タスクもすべて終わったら止まる（デッドロックではない）。
Terminated == ops = MaxOps /\ flushes = MaxFlushes /\ AllDone /\ UNCHANGED vars

Next ==
    \/ Change \/ Clear \/ Flush
    \/ \E t \in Ops : TaskStep(t)
    \/ Terminated

Spec == Init /\ [][Next]_vars /\ \A t \in Ops : WF_vars(TaskStep(t))

(* ---- 検査する性質 ---- *)

TypeOK ==
    /\ ops \in 0..MaxOps
    /\ pending \in 0..MaxOps
    /\ lastSave \in 0..MaxOps
    /\ storage.kind \in {"empty", "data"}

\* ストレージへの書き込みは操作の発行順に起こる（古い State や古い削除が、新しい結果を上書きしない）。
\* 削除どうしの順序の入れ替わりは結果が同じなので許す。
WritesInOrder ==
    \A i, j \in 1..Len(applied) :
        (i < j /\ applied[i] > applied[j]) =>
            tasks[applied[i]].kind = "remove" /\ tasks[applied[j]].kind = "remove"

\* 中身として同じか（空どうしは、どの削除で空になったかを区別しない）。
SameContent(a, b) ==
    a.kind = b.kind /\ (a.kind = "data" => a.op = b.op)

\* タスクがすべて終わったら、ストレージは最後の操作の結果と一致する
\* （clear() 後に保存が戻らない、最後の State が保存される）。
ConsistentWhenIdle ==
    AllDone => SameContent(storage, intent)

\* flush() / clear() が戻った時点で、呼んだ時点の最後の操作（以降）がストレージに反映されている。
WaitersSeeTheirOp ==
    \A w \in waiters : Done(w.on) => LastApplied >= w.target

\* 必ずすべてのタスクが終わる（待ちの循環がない）。
EventuallyIdle == <>AllDone
=============================================================================
