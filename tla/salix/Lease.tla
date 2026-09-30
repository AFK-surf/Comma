------------------------------ MODULE Lease ------------------------------
(***************************************************************************)
(* S3-CAS leases, modeling `SalixCluster.S3Lease` (singletons) and         *)
(* `SalixStore.Lease` (generic keyed leases) — the two are the same        *)
(* protocol: acquire / renew / steal-if-stale / release via conditional    *)
(* writes on one JSON object holding [holder, epoch, lease_until].         *)
(*                                                                         *)
(* Time: staleness (`stale?`) is nondeterministic (see the proposal doc),  *)
(* so any contender may attempt a takeover at any moment.  "Safety is the  *)
(* ETag, never the clock": what the protocol guarantees is                 *)
(*                                                                         *)
(*   - AtMostOneValidToken: at most one holder's token names the live      *)
(*     object.  A deposed holder may still BELIEVE it leads (that is       *)
(*     inherent to leases — see Lease_BeliefExclusion.cfg, an expected-    *)
(*     violation config documenting it), but its next conditional write    *)
(*     or assert_owner fails: no protected S3 write under a stale token    *)
(*     can land.                                                           *)
(*   - NoEpochRegression: while the object exists, its epoch never goes    *)
(*     backwards.                                                          *)
(*                                                                         *)
(* PRECONDITION made explicit by this model: a holder string uniquely      *)
(* identifies ONE live contending process.  `Holder` doubles as process    *)
(* identity here, so two processes sharing a holder string are             *)
(* structurally unrepresentable — and the code's acquire mine-branch and   *)
(* renew verify/2 compare the HOLDER ONLY, so duplicated holder strings    *)
(* would let two processes both validate.  Every current caller uses a     *)
(* node- or process-unique holder; keep it that way.                       *)
(*                                                                         *)
(* Caveat, checked as the expected-violation Lease_EpochReset.cfg: a       *)
(* release DELETEs the object and the next create restarts at epoch 1, so  *)
(* lease epochs are NOT usable as global fencing tokens across             *)
(* release/re-acquire.  No current consumer does (they fence by ETag);     *)
(* the config exists so a future consumer who tries learns it from CI.     *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS Holder,    \* contending holders, e.g. {h1, h2}
          MaxEpoch,  \* state-space bound on takeovers
          MaxFaults, \* ambiguous-outcome budget
          MaxOps     \* budget of applied writes per behavior (bounds the
                     \* ETag space; renew/release/recreate cycles would
                     \* otherwise grow it without bound)

S3 == INSTANCE S3

\* Holders are interchangeable: symmetry reduction for TLC
\* (safety configs only — symmetry is unsound under liveness checking).
HolderSym == Permutations(Holder)

VARIABLES cell,      \* the lease object: val = [holder, epoch]
          token,     \* [Holder -> [etag, epoch]] (etag 0 = no token)
          cap,       \* [Holder -> acquire-time capture [etag, epoch]]
          pc,        \* [Holder -> label]
          faults,
          ops,       \* applied writes so far
          maxEp,     \* ghost: highest epoch ever written
          epochRegressed, \* ghost: an applied PUT lowered the epoch of a live object
          epochReset      \* ghost: a create wrote epoch 1 after a higher epoch existed

vars == <<cell, token, cap, pc, faults, ops, maxEp, epochRegressed, epochReset>>

Labels == {"idle", "a_read", "a_create", "a_take",
           "hold", "r_cas", "r_verify"}
HoldingLabels == {"hold", "r_cas", "r_verify"}

NoTok == [etag |-> 0, epoch |-> 0]

TypeOK ==
  /\ pc \in [Holder -> Labels]
  /\ faults \in 0..MaxFaults
  /\ ops \in 0..MaxOps
  /\ cell.present => cell.val.epoch \in 1..MaxEpoch

Init ==
  /\ cell = S3!EmptyCell
  /\ token = [hd \in Holder |-> NoTok]
  /\ cap = [hd \in Holder |-> NoTok]
  /\ pc = [hd \in Holder |-> "idle"]
  /\ faults = 0
  /\ ops = 0
  /\ maxEp = 0
  /\ epochRegressed = FALSE
  /\ epochReset = FALSE

-----------------------------------------------------------------------------
(* acquire/3: GET, then create (absent), take (mine or stale), or held.    *)

StartAcquire(hd) ==
  /\ pc[hd] = "idle"
  /\ pc' = [pc EXCEPT ![hd] = "a_read"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

AReadAbsent(hd) ==
  /\ pc[hd] = "a_read"
  /\ ~cell.present
  /\ pc' = [pc EXCEPT ![hd] = "a_create"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

\* holder == me, or stale? chose TRUE (nondeterministic steal eligibility).
AReadTake(hd) ==
  /\ pc[hd] = "a_read"
  /\ cell.present
  /\ cell.val.epoch < MaxEpoch    \* state-space bound only
  /\ cap' = [cap EXCEPT ![hd] = [etag |-> S3!ETag(cell), epoch |-> cell.val.epoch]]
  /\ pc' = [pc EXCEPT ![hd] = "a_take"]
  /\ UNCHANGED <<cell, token, faults, epochRegressed, epochReset, ops, maxEp>>

\* held by someone else and stale? chose FALSE -> {:error, {:held_by, ..}}.
AReadHeld(hd) ==
  /\ pc[hd] = "a_read"
  /\ cell.present
  /\ cell.val.holder # hd
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

\* Bound reached: back off (pure state-space bound).
AReadBound(hd) ==
  /\ pc[hd] = "a_read"
  /\ cell.present
  /\ cell.val.epoch >= MaxEpoch
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

\* create/4: PUT if_none_match "*" with epoch 1.
ACreateOk(hd) ==
  /\ pc[hd] = "a_create"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ S3!CanPutIfNoneMatch(cell)
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> 1])
  /\ epochReset' = (epochReset \/ maxEp > 1)
  /\ maxEp' = IF maxEp = 0 THEN 1 ELSE maxEp
  /\ token' = [token EXCEPT ![hd] = [etag |-> S3!ETag(cell'), epoch |-> 1]]
  /\ pc' = [pc EXCEPT ![hd] = "hold"]
  /\ UNCHANGED <<cap, faults, epochRegressed>>

\* 412 -> acquire retries from a fresh GET.
ACreate412(hd) ==
  /\ pc[hd] = "a_create"
  /\ ~S3!CanPutIfNoneMatch(cell)
  /\ pc' = [pc EXCEPT ![hd] = "a_read"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

\* Ambiguous create: surfaces as an error to the caller (no resolve branch
\* in lease.ex create/4) — the holder retries acquire later.  If the write
\* landed, the next GET sees holder == me and recovers via cas_take.
ACreateAmbApplied(hd) ==
  /\ pc[hd] = "a_create"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ faults < MaxFaults
  /\ S3!CanPutIfNoneMatch(cell)
  /\ faults' = faults + 1
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> 1])
  /\ epochReset' = (epochReset \/ maxEp > 1)
  /\ maxEp' = IF maxEp = 0 THEN 1 ELSE maxEp
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<token, cap, epochRegressed>>

ACreateAmbLost(hd) ==
  /\ pc[hd] = "a_create"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, token, cap, epochRegressed, epochReset, ops, maxEp>>

\* cas_take/6: PUT if_match with epoch prev+1.
ATakeOk(hd) ==
  /\ pc[hd] = "a_take"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ S3!CanPutIfMatch(cell, cap[hd].etag)
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> cap[hd].epoch + 1])
  /\ epochRegressed' = (epochRegressed \/ cap[hd].epoch + 1 < cell.val.epoch)
  /\ maxEp' = IF cap[hd].epoch + 1 > maxEp THEN cap[hd].epoch + 1 ELSE maxEp
  /\ token' = [token EXCEPT ![hd] = [etag |-> S3!ETag(cell'), epoch |-> cap[hd].epoch + 1]]
  /\ cap' = [cap EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "hold"]
  /\ UNCHANGED <<faults, epochReset>>

\* 412 -> {:error, {:held_by, :unknown, nil}}: caller backs off.
ATake412(hd) ==
  /\ pc[hd] = "a_take"
  /\ ~S3!CanPutIfMatch(cell, cap[hd].etag)
  /\ cap' = [cap EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, token, faults, epochRegressed, epochReset, ops, maxEp>>

\* Ambiguous take: an error to the caller (no resolve in cas_take); if it
\* landed, the next acquire GET sees holder == me and re-takes.
ATakeAmbApplied(hd) ==
  /\ pc[hd] = "a_take"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ faults < MaxFaults
  /\ S3!CanPutIfMatch(cell, cap[hd].etag)
  /\ faults' = faults + 1
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> cap[hd].epoch + 1])
  /\ epochRegressed' = (epochRegressed \/ cap[hd].epoch + 1 < cell.val.epoch)
  /\ maxEp' = IF cap[hd].epoch + 1 > maxEp THEN cap[hd].epoch + 1 ELSE maxEp
  /\ cap' = [cap EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<token, epochReset>>

ATakeAmbLost(hd) ==
  /\ pc[hd] = "a_take"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ cap' = [cap EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, token, epochRegressed, epochReset, ops, maxEp>>

-----------------------------------------------------------------------------
(* renew/2: PUT if_match token.etag (same holder+epoch, fresh              *)
(* lease_until).  412 -> :lost, fail closed.  Ambiguous -> verify/2: GET   *)
(* and compare holder; adopt the live ETag if still mine, else :lost.      *)

StartRenew(hd) ==
  /\ pc[hd] = "hold"
  /\ pc' = [pc EXCEPT ![hd] = "r_cas"]
  /\ UNCHANGED <<cell, token, cap, faults, epochRegressed, epochReset, ops, maxEp>>

RenewOk(hd) ==
  /\ pc[hd] = "r_cas"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ S3!CanPutIfMatch(cell, token[hd].etag)
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> token[hd].epoch])
  /\ epochRegressed' = (epochRegressed \/ token[hd].epoch < cell.val.epoch)
  /\ token' = [token EXCEPT ![hd].etag = S3!ETag(cell')]
  /\ pc' = [pc EXCEPT ![hd] = "hold"]
  /\ UNCHANGED <<cap, faults, epochReset, maxEp>>

RenewLost(hd) ==
  /\ pc[hd] = "r_cas"
  /\ ~S3!CanPutIfMatch(cell, token[hd].etag)
  /\ token' = [token EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, cap, faults, epochRegressed, epochReset, ops, maxEp>>

RenewAmbApplied(hd) ==
  /\ pc[hd] = "r_cas"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ faults < MaxFaults
  /\ S3!CanPutIfMatch(cell, token[hd].etag)
  /\ faults' = faults + 1
  /\ cell' = S3!Applied(cell, [holder |-> hd, epoch |-> token[hd].epoch])
  /\ epochRegressed' = (epochRegressed \/ token[hd].epoch < cell.val.epoch)
  /\ pc' = [pc EXCEPT ![hd] = "r_verify"]
  /\ UNCHANGED <<token, cap, epochReset, maxEp>>

RenewAmbLost(hd) ==
  /\ pc[hd] = "r_cas"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ pc' = [pc EXCEPT ![hd] = "r_verify"]
  /\ UNCHANGED <<cell, token, cap, epochRegressed, epochReset, ops, maxEp>>

RVerifyMine(hd) ==
  /\ pc[hd] = "r_verify"
  /\ cell.present /\ cell.val.holder = hd
  /\ token' = [token EXCEPT ![hd].etag = S3!ETag(cell)]
  /\ pc' = [pc EXCEPT ![hd] = "hold"]
  /\ UNCHANGED <<cell, cap, faults, epochRegressed, epochReset, ops, maxEp>>

RVerifyLost(hd) ==
  /\ pc[hd] = "r_verify"
  /\ ~cell.present \/ cell.val.holder # hd
  /\ token' = [token EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, cap, faults, epochRegressed, epochReset, ops, maxEp>>

-----------------------------------------------------------------------------
(* renew_if_due HEAD success stutters; failed proof drops the token as Crash. *)
(* TTL selects the path only; renew retains the conditional-write transitions. *)
(* release/1: DELETE if_match token.etag, outcome ignored.  Crash: token   *)
(* gone from memory, object untouched (the stale-takeover case).           *)

ReleaseApplied(hd) ==
  /\ pc[hd] = "hold"
  /\ ops < MaxOps
  /\ ops' = ops + 1
  /\ S3!CanDeleteIfMatch(cell, token[hd].etag)
  /\ cell' = S3!Deleted(cell)
  /\ token' = [token EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cap, faults, epochRegressed, epochReset, maxEp>>

ReleaseNoop(hd) ==
  /\ pc[hd] = "hold"
  /\ ~S3!CanDeleteIfMatch(cell, token[hd].etag)
  /\ token' = [token EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, cap, faults, epochRegressed, epochReset, ops, maxEp>>

Crash(hd) ==
  /\ pc[hd] # "idle"
  /\ token' = [token EXCEPT ![hd] = NoTok]
  /\ cap' = [cap EXCEPT ![hd] = NoTok]
  /\ pc' = [pc EXCEPT ![hd] = "idle"]
  /\ UNCHANGED <<cell, faults, epochRegressed, epochReset, ops, maxEp>>

-----------------------------------------------------------------------------
Next ==
  \E hd \in Holder :
    \/ StartAcquire(hd) \/ AReadAbsent(hd) \/ AReadTake(hd) \/ AReadHeld(hd)
    \/ AReadBound(hd)
    \/ ACreateOk(hd) \/ ACreate412(hd) \/ ACreateAmbApplied(hd) \/ ACreateAmbLost(hd)
    \/ ATakeOk(hd) \/ ATake412(hd) \/ ATakeAmbApplied(hd) \/ ATakeAmbLost(hd)
    \/ StartRenew(hd) \/ RenewOk(hd) \/ RenewLost(hd)
    \/ RenewAmbApplied(hd) \/ RenewAmbLost(hd)
    \/ RVerifyMine(hd) \/ RVerifyLost(hd)
    \/ ReleaseApplied(hd) \/ ReleaseNoop(hd)
    \/ Crash(hd)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants.                                                             *)

ValidToken(hd) ==
  /\ pc[hd] \in HoldingLabels
  /\ cell.present
  /\ token[hd].etag = S3!ETag(cell)

\* The mutual-exclusion the protocol actually provides: at most one
\* holder's token names the live object; every protected conditional write
\* under any other token must fail.
AtMostOneValidToken ==
  \A h1, h2 \in Holder : (h1 # h2) => ~(ValidToken(h1) /\ ValidToken(h2))

\* Token honesty: a valid token belongs to the recorded holder.
ValidTokenHonest ==
  \A hd \in Holder : ValidToken(hd) => cell.val.holder = hd

\* While the object exists, its epoch never regresses.
NoEpochRegression == ~epochRegressed

\* EXPECTED-VIOLATION properties (separate configs):
\* Two holders may simultaneously BELIEVE they lead (one is stale) — leases
\* bound belief only via time, never structurally.
BeliefExclusive ==
  \A h1, h2 \in Holder :
    (h1 # h2) => ~(pc[h1] \in HoldingLabels /\ pc[h2] \in HoldingLabels)

\* Epochs restart at 1 after a release/recreate cycle: NOT usable as global
\* fencing tokens across object lifetimes.
NoEpochResetAcrossRecreate == ~epochReset

=============================================================================
