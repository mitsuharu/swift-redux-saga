---------------------------- MODULE StoreObservation ----------------------------
(***************************************************************************)
(* Store のキーパス単位の通知と scope（Sources/Redux/Store.swift）、         *)
(* Store.observe（Sources/Redux/StoreObservation.swift）のモデル。          *)
(*                                                                         *)
(* View や ObservationToken（観測者）は State のプロパティを読み、          *)
(* Observation に 1 回きりの購読を登録する。Store は読まれたキーパスを      *)
(* 表（trackedKeyPaths）に持ち、値が変わったキーパスを表から外して通知する。 *)
(* 値が変わらないまま読まれなくなったキーパスは、一定の更新回数ごとの掃除で *)
(* 表から外し、そのときも通知する（まだ読んでいる観測者は読み直す）。        *)
(* 通知を受けた観測者は、変更の後にメインアクターで読み直す（Task を挟む）。 *)
(*                                                                         *)
(* scope で作った子の Store は、親の State の一部（ここでは 1 つ目の        *)
(* プロパティ）を持ち、親の通知の後に親から新しい値を知らされて、自分の表で *)
(* 同じように通知する。子の State が変わらなければ、子は何もしない。        *)
(*                                                                         *)
(* Store はメインアクターで動くので、親と子の更新（dispatch から通知まで）  *)
(* と読み直しは、それぞれ割り込まれない手順として扱う。親の更新と子への     *)
(* 伝達は 2 つの手順に分けるが、その間にほかの手順は入らない。             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxUpdates,     \* 更新の回数の上限
    SweepEvery,     \* 何回の更新ごとに掃除するか（実装は max(256, 表の大きさ)）
    SweepNotifies,  \* 掃除で外すキーパスを通知するか（実装は TRUE）
    DeferReread     \* 通知を受けた観測者が、変更の後に読み直すか（実装は TRUE）

\* 親の State のプロパティ 2 つ。子の Store は 1 つ目だけを持つ。
Stores == {"parent", "child"}
KeysOf == [s \in Stores |-> IF s = "parent" THEN {1, 2} ELSE {1}]
AllKeys == {1, 2}

\* 観測者 4 つ: 親の 1 つ目だけ、親の両方、親の 2 つ目だけ、子の 1 つ目を読む。
Observers == {1, 2, 3, 4}
StoreOf == [o \in Observers |-> IF o = 4 THEN "child" ELSE "parent"]
Reads == [o \in Observers |-> CASE o = 1 -> {1} [] o = 2 -> {1, 2} [] o = 3 -> {2} [] o = 4 -> {1}]

VARIABLES
    value,      \* 親の State の各プロパティの値（子の値は 1 つ目と同じ）
    updates,    \* 更新した回数
    tracked,    \* Store ごとの、表にあるキーパス
    lastRead,   \* Store とキーパスごとの、最後に読まれたときの掃除の回数（lastSweepRead）
    sweepCount, \* Store ごとの掃除の回数
    sinceSweep, \* Store ごとの、前回の掃除からの更新の回数
    subscribed, \* 観測者が Observation に購読を登録しているか（1 回通知されると外れる）
    seen,       \* 観測者が最後に読んだ値
    childPending \* 親の通知が終わり、子に新しい値を知らせる前か（その間はほかの手順が入らない）

vars == <<value, updates, tracked, lastRead, sweepCount, sinceSweep, subscribed, seen,
          childPending>>

Init ==
    /\ value = [k \in AllKeys |-> 0]
    /\ updates = 0
    /\ tracked = [s \in Stores |-> {}]
    /\ lastRead = [s \in Stores |-> [k \in AllKeys |-> 0]]
    /\ sweepCount = [s \in Stores |-> 0]
    /\ sinceSweep = [s \in Stores |-> 0]
    \* 最初は購読していない（observe の最初の fire、View の最初の描画の前）。
    /\ subscribed = [o \in Observers |-> FALSE]
    /\ seen = [o \in Observers |-> [k \in Reads[o] |-> 0]]
    /\ childPending = FALSE

\* 観測者が読む（withObservationTracking の read）。読んだキーパスを表に入れ、購読を登録する。
Reread(o) ==
    /\ ~childPending
    /\ ~subscribed[o]
    /\ LET s == StoreOf[o] IN
       /\ seen' = [seen EXCEPT ![o] = [k \in Reads[o] |-> value[k]]]
       /\ subscribed' = [subscribed EXCEPT ![o] = TRUE]
       /\ tracked' = [tracked EXCEPT ![s] = @ \cup Reads[o]]
       /\ lastRead' = [lastRead EXCEPT ![s] =
                        [k \in AllKeys |-> IF k \in Reads[o] THEN sweepCount[s] ELSE @[k]]]
    /\ UNCHANGED <<value, updates, sweepCount, sinceSweep, childPending>>

\* Store s の update(to:) で、キーパス k の値が変わったときの通知（State の代入の前後を含む）。
\* 1. 値が変わったキーパスのうち表にあるものを、表から外す。
\* 2. それを購読している観測者に通知する（willSet）。購読は外れる。
\*    DeferReread でなければ、通知の中でその場で（新しい値になる前に）読み直す。
\* 3. 掃除の回数に達していれば、前回の掃除から読まれていないキーパスを表から外す（通知する）。
\* old はこの Store の、代入の前の値。値の代入（value'）は呼び出し側で行う。
Notify(s, k, old) ==
    LET mine == {o \in Observers : StoreOf[o] = s}
        changed == IF k \in tracked[s] THEN {k} ELSE {}
        notified == {o \in mine : subscribed[o] /\ changed \cap Reads[o] # {}}
        afterNotify == IF DeferReread
                         THEN tracked[s] \ changed
                         ELSE (tracked[s] \ changed) \cup UNION {Reads[o] : o \in notified}
        subsAfter == [o \in Observers |-> IF o \in notified THEN ~DeferReread ELSE subscribed[o]]
        readAfter == [x \in AllKeys |->
                        IF ~DeferReread /\ \E o \in notified : x \in Reads[o]
                          THEN sweepCount[s] ELSE lastRead[s][x]]
        doSweep == sinceSweep[s] + 1 >= SweepEvery
        unread == {x \in afterNotify : readAfter[x] < sweepCount[s]}
        swept == {o \in mine : subsAfter[o] /\ unread \cap Reads[o] # {}}
    IN /\ seen' = [o \in Observers |->
                     IF o \in notified /\ ~DeferReread
                       THEN [x \in Reads[o] |-> old[x]]   \* 古い値を読む
                       ELSE seen[o]]
       /\ lastRead' = [lastRead EXCEPT ![s] = readAfter]
       /\ IF doSweep
            THEN /\ tracked' = [tracked EXCEPT ![s] = afterNotify \ unread]
                 /\ sweepCount' = [sweepCount EXCEPT ![s] = @ + 1]
                 /\ sinceSweep' = [sinceSweep EXCEPT ![s] = 0]
                 /\ subscribed' = IF SweepNotifies
                                    THEN [o \in Observers |-> IF o \in swept THEN FALSE ELSE subsAfter[o]]
                                    ELSE subsAfter
            ELSE /\ tracked' = [tracked EXCEPT ![s] = afterNotify]
                 /\ sinceSweep' = [sinceSweep EXCEPT ![s] = @ + 1]
                 /\ subscribed' = subsAfter
                 /\ UNCHANGED sweepCount

\* 親の Store への dispatch で、キーパス k の値が変わる。
\* 子の State（1 つ目のプロパティ）が変わる場合は、続けて子に知らせる。
Update(k) ==
    /\ ~childPending
    /\ updates < MaxUpdates
    /\ updates' = updates + 1
    /\ Notify("parent", k, value)
    /\ value' = [value EXCEPT ![k] = @ + 1]
    /\ childPending' = (k \in KeysOf["child"])

\* notifyChildren: 子の Store が update(to:) で自分の観測者に知らせる。
\* 子の State が変わらない場合（2 つ目のプロパティだけが変わった場合）は、子は何もしない
\* （update(to:) の最初の比較で戻り、掃除の回数も数えない）。
NotifyChild ==
    /\ childPending
    /\ childPending' = FALSE
    \* 親の値はすでに新しいが、子の currentState はまだ古い（1 つ目のプロパティが 1 つ前の値）。
    /\ Notify("child", 1, [value EXCEPT ![1] = @ - 1])
    /\ UNCHANGED <<value, updates>>

Terminated ==
    /\ ~childPending
    /\ updates = MaxUpdates
    /\ \A o \in Observers : subscribed[o]
    /\ UNCHANGED vars

Next ==
    \/ \E k \in AllKeys : Update(k)
    \/ NotifyChild
    \/ \E o \in Observers : Reread(o)
    \/ Terminated

\* 通知を受けた観測者は、いつか必ず読み直す（Task がメインアクターで実行される）。
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(NotifyChild)
    /\ \A o \in Observers : WF_vars(Reread(o))

(* ---- 検査する性質 ---- *)

\* 購読している観測者が読んだキーパスは、その Store の表にある
\* （表から外れたまま、変化が通知されない購読がない）。
SubscribedKeysAreTracked ==
    \A o \in Observers : subscribed[o] => Reads[o] \subseteq tracked[StoreOf[o]]

\* 通知を待っていない（購読している）観測者は、最新の値を見ている。
\* 値が変わったのに通知されない観測者がいると、この性質が破れる。
\* 子への伝達の途中（親の値は新しく、子はまだ古い）は除く。
SubscribedObserverIsUpToDate ==
    ~childPending =>
        \A o \in Observers : subscribed[o] => \A k \in Reads[o] : seen[o][k] = value[k]

\* 更新が止まれば、すべての観測者がいつか最新の値を見る。
EventuallyUpToDate ==
    <>[](\A o \in Observers : subscribed[o] /\ \A k \in Reads[o] : seen[o][k] = value[k])
=============================================================================
