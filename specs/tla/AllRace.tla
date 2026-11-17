-------------------------------- MODULE AllRace --------------------------------
(***************************************************************************)
(* all / race（Sources/Saga/SagaContext+Combinators.swift）のモデル。       *)
(*                                                                         *)
(* 呼び出し元（all / race を呼んだ Saga）が、fork した処理（branch）の終わり *)
(* を waitForAny で待ち、終わり方に応じて値を返す、エラーを投げる、残りを   *)
(* キャンセルする。branch は成功・失敗（本体か、本体が fork した子の失敗）・ *)
(* キャンセルのどれでも終わり得て、呼び出し元もいつでもキャンセルされ得る。 *)
(*                                                                         *)
(* waitForAny は 1 回の待ちごとに gate（1 回だけ取り出せる continuation）を *)
(* 作り、branch の終わりを知らせる observer と onCancel のうち先に gate を  *)
(* 取った方だけが再開する。前の待ちの observer が後から呼ばれても、新しい   *)
(* 待ちの gate に触れないことを、待ちの世代（gen）で表している。           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    N,                  \* branch の数
    Mode,               \* "all" か "race"
    CheckCancelAtReturn \* 戻る前に呼び出し元のキャンセルを確かめるか

B == 1..N
NoGen == 0
\* waitForAny の戻り値。branch の位置（1..N）か、次のどちらか。
None == 0
Cancel == N + 1

VARIABLES
    status,     \* branch の終わり方（SagaTaskState.status）。"none" は実行中
    result,     \* branch が残した結果（Branch.result）
    bodyDone,   \* branch の本体が値を返したか
    cancelReq,  \* branch に cancel() が呼ばれたか
    obs,        \* branch に登録されている observer の世代（NoGen なら未登録）
    pendingFire,\* 終わり方の確定で取り出され、まだ呼ばれていない observer の世代
    callerCancelled, \* 呼び出し元のタスクがキャンセルされたか
    handlerGen, \* まだ実行されていない onCancel の世代
    gen,        \* waitForAny の待ちの世代
    gate,       \* 今の待ちの gate が continuation を持っているか
    resumeVal,  \* gate から再開した値（branch の位置か Cancel）。None はまだ
    doubleResume, \* 1 つの待ちを 2 回再開しようとしたか
    cpc,        \* 呼び出し元の状態
    regIdx,     \* observer を登録している branch の位置
    remaining,  \* all がまだ終わりを待っている branch
    got,        \* waitForAny が返したもの
    outcome,    \* all / race の結果: "value" / "error" / "cancel"
    cancelledAtReturn \* 戻った時点で呼び出し元がキャンセルされていたか

vars == <<status, result, bodyDone, cancelReq, obs, pendingFire, callerCancelled, handlerGen,
          gen, gate, resumeVal, doubleResume, cpc, regIdx, remaining, got, outcome,
          cancelledAtReturn>>

branchVars == <<status, result, bodyDone, cancelReq, obs, pendingFire>>
waitVars == <<handlerGen, gen, gate, resumeVal, doubleResume, regIdx>>

Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Candidates == IF Mode = "all" THEN remaining ELSE B

Cancelling(b) == cancelReq[b] \/ callerCancelled

Init ==
    /\ status = [b \in B |-> "none"]
    /\ result = [b \in B |-> "none"]
    /\ bodyDone = [b \in B |-> FALSE]
    /\ cancelReq = [b \in B |-> FALSE]
    /\ obs = [b \in B |-> NoGen]
    /\ pendingFire = [b \in B |-> NoGen]
    /\ callerCancelled = FALSE
    /\ handlerGen = NoGen
    /\ gen = 0
    /\ gate = FALSE
    /\ resumeVal = None
    /\ doubleResume = FALSE
    /\ cpc = "check"
    /\ regIdx = 1
    /\ remaining = B
    /\ got = None
    /\ outcome = "none"
    /\ cancelledAtReturn = FALSE

(* ---- branch ---- *)

\* 終わり方を確定する（SagaTaskState.finish）。登録されていた observer を取り出す。
Finish(b, st) ==
    /\ status' = [status EXCEPT ![b] = st]
    /\ pendingFire' = [pendingFire EXCEPT ![b] = obs[b]]
    /\ obs' = [obs EXCEPT ![b] = NoGen]

\* 本体が値を返す（branch.finish(.success(...))）。キャンセルに応じない処理は、キャンセル後も値を返し得る。
BodySucceed(b) ==
    /\ status[b] = "none" /\ ~bodyDone[b]
    /\ bodyDone' = [bodyDone EXCEPT ![b] = TRUE]
    /\ result' = [result EXCEPT ![b] = "ok"]
    /\ UNCHANGED <<status, cancelReq, obs, pendingFire>>

\* 本体と子がすべて終わり、終わり方を確定する（runForked の正常終了）。
FinishOk(b) ==
    /\ status[b] = "none" /\ bodyDone[b]
    /\ Finish(b, IF Cancelling(b) THEN "cancelled" ELSE "completed")
    /\ UNCHANGED <<result, bodyDone, cancelReq>>

\* 本体か、本体が fork した子が失敗する。キャンセル中ならキャンセルとして終わる。
\* そうでなければ onFailure（branch.finish(.failure)）の後に終わり方を確定する。
Fail(b) ==
    /\ status[b] = "none"
    /\ IF Cancelling(b)
         THEN /\ Finish(b, "cancelled") /\ UNCHANGED result
         ELSE /\ result' = [result EXCEPT ![b] = "err"]
              /\ Finish(b, "failed")
    /\ UNCHANGED <<bodyDone, cancelReq>>

\* キャンセルに応じて終わる（CancellationError）。
Cancelled(b) ==
    /\ status[b] = "none" /\ Cancelling(b)
    /\ Finish(b, "cancelled")
    /\ UNCHANGED <<result, bodyDone, cancelReq>>

BranchStep(b) ==
    /\ (BodySucceed(b) \/ FinishOk(b) \/ Fail(b) \/ Cancelled(b))
    /\ UNCHANGED <<callerCancelled, cpc, remaining, got, outcome, cancelledAtReturn>>
    /\ UNCHANGED waitVars

\* gate を取り出して再開する（takeGate）。gate が空なら何もしない。
TakeGate(v) ==
    /\ gate' = FALSE
    /\ resumeVal' = v
    /\ doubleResume' = (doubleResume \/ resumeVal # None)

\* 取り出された observer が呼ばれる（fire）。古い待ちの observer なら gate に触れない。
Fire(b) ==
    /\ pendingFire[b] # NoGen
    /\ pendingFire' = [pendingFire EXCEPT ![b] = NoGen]
    /\ IF pendingFire[b] = gen /\ gate
         THEN TakeGate(b)
         ELSE UNCHANGED <<gate, resumeVal, doubleResume>>
    /\ UNCHANGED <<status, result, bodyDone, cancelReq, obs, callerCancelled, handlerGen, gen,
                   cpc, regIdx, remaining, got, outcome, cancelledAtReturn>>

(* ---- 呼び出し元 ---- *)

InWait == cpc \in {"lock", "register", "suspended"}

\* 呼び出し元のタスクがキャンセルされる。branch は呼び出し元の子タスクなので、branch にも伝わる。
\* waitForAny の中なら onCancel が（いつか）実行される。
CallerCancel ==
    /\ ~callerCancelled /\ cpc # "returned"
    /\ callerCancelled' = TRUE
    /\ handlerGen' = IF InWait THEN gen ELSE handlerGen
    /\ UNCHANGED <<branchVars, gen, gate, resumeVal, doubleResume, cpc, regIdx, remaining, got,
                   outcome, cancelledAtReturn>>

\* onCancel: gate を取り出せれば CancellationError で再開する。
OnCancel ==
    /\ handlerGen # NoGen
    /\ handlerGen' = NoGen
    /\ IF handlerGen = gen /\ gate
         THEN TakeGate(Cancel)
         ELSE UNCHANGED <<gate, resumeVal, doubleResume>>
    /\ UNCHANGED <<branchVars, callerCancelled, gen, cpc, regIdx, remaining, got, outcome,
                   cancelledAtReturn>>

\* waitForAny の最初: すでに終わっている候補があれば、位置の小さいものを返す。
\* なければ新しい待ちを作り、withTaskCancellationHandler に入る（キャンセル済みなら onCancel がすぐ走る）。
Check ==
    /\ cpc = "check"
    /\ LET fin == {b \in Candidates : status[b] # "none"} IN
       IF fin # {}
         THEN /\ got' = Min(fin) /\ cpc' = "decide"
              /\ UNCHANGED <<gen, handlerGen>>
         ELSE /\ gen' = gen + 1
              /\ handlerGen' = IF callerCancelled THEN gen + 1 ELSE handlerGen
              /\ cpc' = "lock"
              /\ UNCHANGED got
    /\ UNCHANGED <<branchVars, callerCancelled, gate, resumeVal, doubleResume, regIdx, remaining,
                   outcome, cancelledAtReturn>>

\* gate に continuation を置く。キャンセル済みなら置かずに CancellationError で戻る。
Lock ==
    /\ cpc = "lock"
    /\ IF callerCancelled
         THEN /\ got' = Cancel /\ cpc' = "afterWait"
              /\ UNCHANGED <<gate, regIdx>>
         ELSE /\ gate' = TRUE /\ regIdx' = 1 /\ cpc' = "register"
              /\ UNCHANGED got
    /\ UNCHANGED <<branchVars, callerCancelled, handlerGen, gen, resumeVal, doubleResume,
                   remaining, outcome, cancelledAtReturn>>

\* 候補に 1 つずつ observer を登録する。すでに終わっていれば、その場で fire する。
Register ==
    /\ cpc = "register"
    /\ IF regIdx > N
         THEN /\ cpc' = "suspended"
              /\ UNCHANGED <<obs, regIdx, gate, resumeVal, doubleResume>>
         ELSE /\ regIdx' = regIdx + 1
              /\ UNCHANGED cpc
              /\ IF regIdx \notin Candidates
                   THEN UNCHANGED <<obs, gate, resumeVal, doubleResume>>
                 ELSE IF status[regIdx] = "none"
                   THEN /\ obs' = [obs EXCEPT ![regIdx] = gen]
                        /\ UNCHANGED <<gate, resumeVal, doubleResume>>
                 ELSE /\ UNCHANGED obs
                      /\ IF gate THEN TakeGate(regIdx)
                         ELSE UNCHANGED <<gate, resumeVal, doubleResume>>
    /\ UNCHANGED <<status, result, bodyDone, cancelReq, pendingFire, callerCancelled, handlerGen,
                   gen, remaining, got, outcome, cancelledAtReturn>>

\* 再開されて waitForAny から戻る。
Resume ==
    /\ cpc = "suspended" /\ resumeVal # None
    /\ got' = resumeVal
    /\ resumeVal' = None
    /\ cpc' = "afterWait"
    /\ UNCHANGED <<branchVars, callerCancelled, handlerGen, gen, gate, doubleResume, regIdx,
                   remaining, outcome, cancelledAtReturn>>

\* defer で observer を外す（すでに取り出された observer は、後から呼ばれ得る）。
AfterWait ==
    /\ cpc = "afterWait"
    /\ obs' = [b \in B |-> IF obs[b] = gen THEN NoGen ELSE obs[b]]
    /\ cpc' = "decide"
    /\ UNCHANGED <<status, result, bodyDone, cancelReq, pendingFire, callerCancelled, handlerGen,
                   gen, gate, resumeVal, doubleResume, regIdx, remaining, got, outcome,
                   cancelledAtReturn>>

CancelAll == cancelReq' = [b \in B |-> IF status[b] = "none" THEN TRUE ELSE cancelReq[b]]
CancelOthers(w) ==
    cancelReq' = [b \in B |-> IF b # w /\ status[b] = "none" THEN TRUE ELSE cancelReq[b]]

\* all / race から戻る。修正後の実装は、値やエラーを返す前に呼び出し元のキャンセルを確かめる。
Return(o) ==
    /\ outcome' = IF CheckCancelAtReturn /\ callerCancelled THEN "cancel" ELSE o
    /\ cancelledAtReturn' = callerCancelled
    /\ cpc' = "returned"

DecideAll ==
    /\ cpc = "decide" /\ Mode = "all"
    /\ IF got = Cancel
         THEN /\ Return("cancel") /\ UNCHANGED <<cancelReq, remaining>>
         ELSE LET rest == remaining \ {got} IN
              /\ remaining' = rest
              /\ CASE result[got] = "ok" ->
                        IF rest = {}
                          THEN Return("value") /\ UNCHANGED cancelReq
                          ELSE cpc' = "check" /\ UNCHANGED <<cancelReq, outcome, cancelledAtReturn>>
                   [] result[got] = "err" -> CancelAll /\ Return("error")
                   [] result[got] = "none" -> CancelAll /\ Return("cancel")
    /\ UNCHANGED <<status, result, bodyDone, obs, pendingFire, callerCancelled, waitVars, got>>

DecideRace ==
    /\ cpc = "decide" /\ Mode = "race"
    /\ IF got = Cancel
         THEN CancelAll /\ Return("cancel")
         ELSE /\ CancelOthers(got)
              /\ Return(CASE result[got] = "ok" -> "value"
                          [] result[got] = "err" -> "error"
                          [] result[got] = "none" -> "cancel")
    /\ UNCHANGED <<status, result, bodyDone, obs, pendingFire, callerCancelled, waitVars, got,
                   remaining>>

CallerStep == Check \/ Lock \/ Register \/ Resume \/ AfterWait \/ DecideAll \/ DecideRace

\* 呼び出し元が戻り、branch もすべて終わり、呼ばれる observer も残っていなければ止まる。
Terminated ==
    /\ cpc = "returned"
    /\ \A b \in B : status[b] # "none" /\ pendingFire[b] = NoGen
    /\ handlerGen = NoGen
    /\ UNCHANGED vars

Next ==
    \/ CallerStep \/ CallerCancel \/ OnCancel
    \/ \E b \in B : BranchStep(b) \/ Fire(b)
    \/ Terminated

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(CallerStep) /\ WF_vars(OnCancel)
    /\ \A b \in B : WF_vars(BranchStep(b)) /\ WF_vars(Fire(b))

(* ---- 検査する性質 ---- *)

Returned == cpc = "returned"

\* 1 つの待ちを 2 回再開しない（CheckedContinuation ならクラッシュする）。
NoDoubleResume == ~doubleResume

\* 呼び出し元がキャンセルされた後に、値やエラーを返さない（call と同じく、キャンセル後の古い結果を put させない）。
NoStaleOutcome == Returned /\ cancelledAtReturn => outcome = "cancel"

\* 戻ったとき、終わっていない branch はすべてキャンセルを要求されている（取り残さない）。
NoOrphanBranch ==
    Returned => \A b \in B : status[b] # "none" \/ cancelReq[b] \/ callerCancelled

\* 値を返すのは、all ならすべて、race なら勝者が値を残したときだけ。
ValueIsReal ==
    Returned /\ outcome = "value" =>
        IF Mode = "all" THEN \A b \in B : result[b] = "ok" ELSE result[got] = "ok"

\* エラーを投げるのは、どれかの branch が失敗したときだけ。
ErrorIsReal == Returned /\ outcome = "error" => \E b \in B : result[b] = "err"

\* 呼び出し元がキャンセルされていないのに CancellationError で戻るのは、branch がキャンセルで終わったときだけ。
CancelIsReal ==
    Returned /\ outcome = "cancel" /\ ~callerCancelled =>
        \E b \in B : status[b] = "cancelled" \/ result[b] = "none"

\* all / race は必ず戻る（待ちが失われない）。
EventuallyReturns == <>Returned
=============================================================================
