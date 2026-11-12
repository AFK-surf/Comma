------------------------- MODULE SessionHotArchive -------------------------
(***************************************************************************)
(* Session PG revisions, frozen business submissions, and archive transfer. *)
(* The hot cell abstracts committed PG control and the logical hot window. *)
(* S3!Applied supplies only a versioned atomic cell, not an S3 hot backend. *)
(* Business submissions carry fid (storage_revision) and a frozen revision.*)
(* A lost response can leave an in-flight write. Retrying keeps that exact *)
(* candidate. Upstream acknowledgement requires confirmed durability.      *)
(*                                                                         *)
(* ArchiveAppend captures a bounded prefix of committed records.          *)
(* The archive value abstracts immutable segments; publication monotonicity*)
(* is assumed here and checked separately by ArchiveAppend. ArchiveAdvance *)
(* is an independent PG maintenance transaction. It advances SQL revision, *)
(* preserves fid/control, and publishes the directory, watermark and      *)
(* physical body removal in one transaction.                              *)
(* A business settlement returns its original base+1 revision, even when   *)
(* maintenance has advanced the row. A later write whose base fid is still *)
(* the row's lands over that advance and reloads (ArchiveRebase).          *)
(* This maps PG.apply_pending, PG.apply_locked and PG.publish_archive.     *)
(* It does not prove SQL refinement, byte limits, or worker scheduling.   *)
(*                                                                         *)
(* log is the physical PG body range. Publication removes its cut         *)
(* atomically. Runtime context can retain cold uncompacted records.        *)
(* Runtime tests cover RR readers, context restoration and atomic DELETE. *)
(*                                                                         *)
(* Negative configs retain the original failures: blind rematerialization,*)
(* watermark publication before content, and archiving uncommitted input.  *)
(* LateApplyInFlight permits a still-pending request to land after a read.  *)
(* Fault budgets bound crashes and ambiguous writes. FairSpec adds weak    *)
(* owner-step fairness; it assumes available storage, not permanent faults.*)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Nodes, MaxSeq, Payloads, MaxCrash, MaxAmb, MaxFid,
          SettleByFlushId, CreateBeforeAdvance, ChunkFromDurable,
          LateApplyInFlight

S3 == INSTANCE S3
Seqs == 1..MaxSeq
Events == 1..MaxSeq
NodeSym == Permutations(Nodes)

(* The archive is ONE append-only object holding a prefix of the log:     *)
(* its value is the sequence of records 1..Len(val).                      *)
(*                                                                        *)
(* Segment bytes are immutable. This value abstracts their logical prefix.*)
(* Directory publication preserves that prefix; ArchiveAppend checks the  *)
(* conditional monotone publication boundary separately. Versions of the  *)
(* logical byte prefix are immaterial here.                               *)
ArchiveApplied(v) == [present |-> TRUE, val |-> v, ver |-> 0]

VARIABLES hot,      \* PG revision cell: val = [last, arch, comp, fid, log]
          arcv,     \* the ONE archive object: a cell holding a log prefix
          role,     \* [Nodes -> {"down","owner"}]
          lver,     \* [Nodes -> Nat] revision of the durable-confirmed base
          lval,     \* [Nodes -> hot val] durable-confirmed view
          mlog,     \* [Nodes -> partial fn] in-memory appends past lval.last
          mlast, mcomp, march,   \* [Nodes -> Nat] in-memory working values
          fpc,      \* [Nodes -> {"idle","inflight","resolve"}]
          pend,     \* [Nodes -> [val, fid, evs]] the in-flight flush
          requeue,  \* [Nodes -> SUBSET Events] believed-unflushed events
          zomb,     \* detached in-flight writes of crashed owners
          nextFid, nextEv, crashes, ambs,
          dur,      \* ghost: [Seqs -> Payloads \cup {0}] payload fixed at
                    \* first durability; 0 = never durable
          evOf,     \* ghost: [Seqs -> Events \cup {0}] event behind a seq
          acked     \* ghost: <<seq, payload>> pairs confirmed upstream

vars == <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march, fpc, pend,
          requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf, acked>>

Rec == [ev : Events, p : Payloads]
NoPend == [val |-> <<>>, fid |-> 0, evs |-> {}]

EmptyVal == [last |-> 0, arch |-> 0, comp |-> 0, fid |-> 0,
             log |-> [s \in {} |-> <<>>]]

TypeOK ==
  /\ hot.present /\ hot.ver \in Nat
  /\ role \in [Nodes -> {"down", "owner"}]
  /\ fpc \in [Nodes -> {"idle", "inflight", "resolve"}]
  /\ dur \in [Seqs -> Payloads \cup {0}]
  /\ evOf \in [Seqs -> Events \cup {0}]
  /\ \A n \in Nodes : role[n] = "down" => fpc[n] = "idle"
  /\ crashes \in 0..MaxCrash /\ ambs \in 0..MaxAmb

Init ==
  /\ hot = S3!Applied(S3!EmptyCell, EmptyVal)
  /\ arcv = S3!EmptyCell
  /\ role = [n \in Nodes |-> "down"]
  /\ lver = [n \in Nodes |-> 0]
  /\ lval = [n \in Nodes |-> EmptyVal]
  /\ mlog = [n \in Nodes |-> [s \in {} |-> <<>>]]
  /\ mlast = [n \in Nodes |-> 0] /\ mcomp = [n \in Nodes |-> 0]
  /\ march = [n \in Nodes |-> 0]
  /\ fpc = [n \in Nodes |-> "idle"]
  /\ pend = [n \in Nodes |-> NoPend]
  /\ requeue = [n \in Nodes |-> {}]
  /\ zomb = {}
  /\ nextFid = 1 /\ nextEv = 1 /\ crashes = 0 /\ ambs = 0
  /\ dur = [s \in Seqs |-> 0] /\ evOf = [s \in Seqs |-> 0]
  /\ acked = {}

(* The owner's full in-memory log: durable-confirmed window plus appends. *)
Full(n) == lval[n].log @@ mlog[n]

(* Window carried by the next flush: everything past the working watermark. *)
BuildVal(n, fid) ==
  [last |-> mlast[n], arch |-> march[n], comp |-> mcomp[n], fid |-> fid,
   log  |-> [s \in {x \in Seqs : x > march[n] /\ x <= mlast[n]} |-> Full(n)[s]]]

(* Ghost bookkeeping for an applied hot write: payloads and events of the  *)
(* newly durable seqs are fixed forever at this instant.                   *)
FixDur(v) ==
  /\ dur' = [s \in Seqs |->
       IF s > hot.val.last /\ s \in DOMAIN v.log THEN v.log[s].p ELSE dur[s]]
  /\ evOf' = [s \in Seqs |->
       IF s > hot.val.last /\ s \in DOMAIN v.log THEN v.log[s].ev ELSE evOf[s]]

(* Seqs this flush makes durable, relative to the writer's confirmed base *)
(* (equal to the pre-apply hot state whenever its CAS can land).           *)
NewPairs(n, v) == {<<s, v.log[s].p>> : s \in {x \in DOMAIN v.log :
                    x > lval[n].last}}

(***************************************************************************)
(* Activation / rehome.  Loading is always allowed for a down node: a new  *)
(* believer may arise while the old owner still runs.                      *)
(***************************************************************************)
Load(n) ==
  /\ role[n] = "down"
  /\ role' = [role EXCEPT ![n] = "owner"]
  /\ lver' = [lver EXCEPT ![n] = hot.ver]
  /\ lval' = [lval EXCEPT ![n] = hot.val]
  /\ mlog' = [mlog EXCEPT ![n] = [s \in {} |-> <<>>]]
  /\ mlast' = [mlast EXCEPT ![n] = hot.val.last]
  /\ mcomp' = [mcomp EXCEPT ![n] = hot.val.comp]
  /\ march' = [march EXCEPT ![n] = hot.val.arch]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ requeue' = [requeue EXCEPT ![n] = {}]
  /\ UNCHANGED <<hot, arcv, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

AppendWith(n, e, p) ==
  /\ mlog' = [mlog EXCEPT ![n] = @ @@ ((mlast[n] + 1) :> [ev |-> e, p |-> p])]
  /\ mlast' = [mlast EXCEPT ![n] = @ + 1]

(* A fresh upstream input materialized into the in-memory log.  The       *)
(* payload choice models every nondeterministic value fixed at            *)
(* materialization time (ids, timestamps).                                *)
AppendFresh(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle"
  /\ mlast[n] < MaxSeq /\ nextEv <= MaxSeq
  /\ \E p \in Payloads : AppendWith(n, nextEv, p)
  /\ nextEv' = nextEv + 1
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mcomp, march, fpc, pend,
                 requeue, zomb, nextFid, crashes, ambs, dur, evOf, acked>>

(* Blind-settlement mode only: an event the actor wrongly believes        *)
(* unflushed is materialized again, with fresh nondeterministic values.   *)
AppendRequeued(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle"
  /\ mlast[n] < MaxSeq
  /\ \E e \in requeue[n], p \in Payloads :
       /\ AppendWith(n, e, p)
       /\ requeue' = [requeue EXCEPT ![n] = @ \ {e}]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mcomp, march, fpc, pend,
                 zomb, nextFid, nextEv, crashes, ambs, dur, evOf, acked>>

(* Compaction moves the watermark; the summary itself is out of scope.    *)
(* The safe rule only compacts durable-confirmed records.                 *)
Compact(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle"
  /\ LET bound == IF ChunkFromDurable THEN lval[n].last ELSE mlast[n]
     IN \E c \in (mcomp[n] + 1)..bound :
          mcomp' = [mcomp EXCEPT ![n] = c]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, march, fpc, pend,
                 requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

(***************************************************************************)
(* Archive step 1: create immutable content from a committed prefix.     *)
(* The finite cut may stop before last. Existing content owns its boundary *)
(* and stays unchanged while later committed records extend the prefix.   *)
(***************************************************************************)
ArchiveAppend(n) ==
  /\ LET src   == IF ChunkFromDurable THEN hot.val.log ELSE Full(n)
         bound == IF ChunkFromDurable THEN hot.val.last ELSE mlast[n]
         have  == Len(arcv.val)
     IN \E target \in (have + 1)..bound :
          /\ \A i \in (have + 1)..target : i \in DOMAIN src
          /\ arcv' = ArchiveApplied(
                       [i \in 1..target |->
                          IF i <= have THEN arcv.val[i] ELSE src[i]])
  /\ UNCHANGED <<hot, role, lver, lval, mlog, mlast, mcomp, march, fpc, pend,
                 requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

(* Archive step 2: publish one landed cut and remove its PG bodies.        *)
(* A later business append does not invalidate the captured prefix.       *)
(* The SQL row lock preserves current control and the last business fid.  *)
ArchiveAdvance(n) ==
  /\ LET upper == IF CreateBeforeAdvance
                    THEN IF Len(arcv.val) < hot.val.last
                         THEN Len(arcv.val) ELSE hot.val.last
                    ELSE hot.val.last
     IN \E through \in (hot.val.arch + 1)..upper :
          LET value == [hot.val EXCEPT !.arch = through,
                          !.log = [s \in {x \in DOMAIN hot.val.log : x > through}
                                   |-> hot.val.log[s]]]
          IN hot' = S3!Applied(hot, value)
  /\ UNCHANGED <<arcv, role, lver, lval, mlog, mlast, mcomp, march, fpc, pend,
                 requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

(***************************************************************************)
(* The business commit: one expected-revision PG transaction.                                   *)
(***************************************************************************)
BeginFlush(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle" /\ nextFid <= MaxFid
  /\ BuildVal(n, 0) # [lval[n] EXCEPT !.fid = 0]
  /\ pend' = [pend EXCEPT ![n] =
       [val |-> BuildVal(n, nextFid), fid |-> nextFid,
        evs |-> {mlog[n][s].ev : s \in DOMAIN mlog[n]}]]
  /\ nextFid' = nextFid + 1
  /\ fpc' = [fpc EXCEPT ![n] = "inflight"]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 requeue, zomb, nextEv, crashes, ambs, dur, evOf, acked>>

AdoptPend(n) ==
  /\ lver' = [lver EXCEPT ![n] = @ + 1]
  /\ lval' = [lval EXCEPT ![n] = pend[n].val]
  /\ mlog' = [mlog EXCEPT ![n] = [s \in {} |-> <<>>]]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ acked' = acked \cup NewPairs(n, pend[n].val)

(* CAS applied and the response arrived: confirm, then ack upstream.      *)
FlushOk(n) ==
  /\ fpc[n] = "inflight" /\ hot.ver = lver[n]
  /\ hot' = S3!Applied(hot, pend[n].val)
  /\ FixDur(pend[n].val)
  /\ AdoptPend(n)
  /\ UNCHANGED <<arcv, role, mlast, mcomp, march, pend, requeue, zomb,
                 nextFid, nextEv, crashes, ambs>>

(* CAS applied but the response was lost: ambiguous, no ack yet.          *)
FlushAmbApplied(n) ==
  /\ fpc[n] = "inflight" /\ hot.ver = lver[n] /\ ambs < MaxAmb
  /\ hot' = S3!Applied(hot, pend[n].val)
  /\ FixDur(pend[n].val)
  /\ fpc' = [fpc EXCEPT ![n] = "resolve"]
  /\ ambs' = ambs + 1
  /\ UNCHANGED <<arcv, role, lver, lval, mlog, mlast, mcomp, march, pend,
                 requeue, zomb, nextFid, nextEv, crashes, acked>>

(* Request lost before applying: ambiguous from the writer's seat.        *)
FlushAmbLost(n) ==
  /\ fpc[n] = "inflight" /\ ambs < MaxAmb
  /\ fpc' = [fpc EXCEPT ![n] = "resolve"]
  /\ ambs' = ambs + 1
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 pend, requeue, zomb, nextFid, nextEv, crashes, dur, evOf,
                 acked>>

(* Ambiguous while the request is STILL IN FLIGHT: the owner learns        *)
(* nothing and the write may land at any later point (ZombieApply), which  *)
(* is exactly what makes a settlement read not a fence.                    *)
FlushAmbInFlight(n) ==
  /\ LateApplyInFlight
  /\ fpc[n] = "inflight" /\ ambs < MaxAmb
  /\ zomb' = zomb \cup {[reqVer |-> lver[n], val |-> pend[n].val]}
  /\ fpc' = [fpc EXCEPT ![n] = "resolve"]
  /\ ambs' = ambs + 1
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 pend, requeue, nextFid, nextEv, crashes, dur, evOf, acked>>

(* Definite CAS rejection: someone else moved the object — deposed.       *)
(* Our own write explains the move: it is still in flight, or it has      *)
(* already landed and carries our flush_id.  A 412 is then NOT proof of    *)
(* "did not land".                                                        *)
OwnWriteExplains(n) ==
  \/ \E z \in zomb : z.val.fid = pend[n].fid
  \/ hot.val.fid = pend[n].fid

FlushReject(n) ==
  /\ fpc[n] = "inflight" /\ hot.ver # lver[n]
  /\ ~OwnWriteExplains(n) /\ hot.val.fid # lval[n].fid
  /\ role' = [role EXCEPT ![n] = "down"]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ UNCHANGED <<hot, arcv, lver, lval, mlog, mlast, mcomp, march, requeue,
                 zomb, nextFid, nextEv, crashes, ambs, dur, evOf, acked>>

(* The implementation's fix: a rejection our own in-flight/landed write    *)
(* can explain is re-settled by read-back instead of handing the batch     *)
(* back to the caller (which would re-materialize dedupe-less records).    *)
FlushRejectResettle(n) ==
  /\ fpc[n] = "inflight" /\ hot.ver # lver[n]
  /\ OwnWriteExplains(n)
  /\ fpc' = [fpc EXCEPT ![n] = "resolve"]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 pend, requeue, zomb, nextFid, nextEv, crashes, ambs, dur,
                 evOf, acked>>

(* Only maintenance moved the row since the writer's base: its fid is the   *)
(* base's. The write lands over the advance: new records go into the hot   *)
(* window above the published watermark, and the owner adopts the row.    *)
(* A pending write of its own that already landed is ResolveLanded.        *)
ArchiveRebase(n) ==
  /\ fpc[n] \in {"inflight", "resolve"} /\ SettleByFlushId
  /\ hot.ver # lver[n] /\ hot.val.fid = lval[n].fid
  /\ hot.val.fid # pend[n].fid
  /\ LET value == [pend[n].val EXCEPT !.arch = hot.val.arch,
                      !.log = [s \in {x \in DOMAIN pend[n].val.log : x > hot.val.arch}
                               |-> pend[n].val.log[s]]]
     IN /\ hot' = S3!Applied(hot, value)
        /\ FixDur(value)
        /\ lver' = [lver EXCEPT ![n] = hot.ver + 1]
        /\ lval' = [lval EXCEPT ![n] = value]
        /\ march' = [march EXCEPT ![n] = hot.val.arch]
  /\ mlog' = [mlog EXCEPT ![n] = [s \in {} |-> <<>>]]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ acked' = acked \cup NewPairs(n, pend[n].val)
  /\ UNCHANGED <<arcv, role, mlast, mcomp, pend, requeue, zomb, nextFid,
                 nextEv, crashes, ambs>>

(***************************************************************************)
(* Ambiguity settlement: read the committed Session row.                         *)
(* Safe rule: own storage identity -> landed; unchanged base -> retry the            *)
(* SAME pend (one flush_id, one materialization); else deposed.            *)
(* Blind rule (violation): compare revisions only and rebase on any change,    *)
(* requeueing the batch — which duplicates it when the write had landed.   *)
(***************************************************************************)
(* fid confirms the original business submission. Maintenance can change  *)
(* the watermark and row revision without changing that identity.          *)
ResolveLanded(n) ==
  /\ fpc[n] = "resolve" /\ SettleByFlushId
  /\ hot.val.fid = pend[n].fid
  /\ hot' = hot
  /\ AdoptPend(n)
  /\ UNCHANGED <<arcv, role, mlast, mcomp, march, pend, requeue, zomb,
                 nextFid, nextEv, crashes, ambs, dur, evOf>>

ResolveNotLanded(n) ==
  /\ fpc[n] = "resolve" /\ SettleByFlushId
  /\ hot.val.fid # pend[n].fid /\ hot.ver = lver[n]
  /\ fpc' = [fpc EXCEPT ![n] = "inflight"]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 pend, requeue, zomb, nextFid, nextEv, crashes, ambs, dur,
                 evOf, acked>>

ResolveDeposed(n) ==
  /\ fpc[n] = "resolve" /\ SettleByFlushId
  /\ hot.val.fid # pend[n].fid /\ hot.ver # lver[n]
  /\ hot.val.fid # lval[n].fid
  /\ role' = [role EXCEPT ![n] = "down"]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ UNCHANGED <<hot, arcv, lver, lval, mlog, mlast, mcomp, march, requeue,
                 zomb, nextFid, nextEv, crashes, ambs, dur, evOf, acked>>

(* Settlement read-back failures are model stutter (the owner learns      *)
(* nothing and stays in resolve); their bounded budget surfaces as the     *)
(* exhaustion transition below. Budget exhaustion while the outcome is     *)
(* unknown: the owner gives up WITHOUT requeueing the pending batch        *)
(* (commit_indeterminate). The write may or may not be durable; the only  *)
(* safe continuation is going down and rehydrating — a blind requeue is    *)
(* exactly the duplication the settlement exists to prevent. Modeled as    *)
(* deposition with no knowledge of `hot`, consuming fault budget so the    *)
(* state space stays bounded.                                              *)
ResolveIndeterminate(n) ==
  /\ fpc[n] = "resolve" /\ SettleByFlushId /\ ambs < MaxAmb
  /\ ambs' = ambs + 1
  /\ role' = [role EXCEPT ![n] = "down"]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ UNCHANGED <<hot, arcv, lver, lval, mlog, mlast, mcomp, march, requeue,
                 zomb, nextFid, nextEv, crashes, dur, evOf, acked>>

ResolveBlindRetry(n) ==
  /\ fpc[n] = "resolve" /\ ~SettleByFlushId
  /\ hot.ver = lver[n]
  /\ fpc' = [fpc EXCEPT ![n] = "inflight"]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march,
                 pend, requeue, zomb, nextFid, nextEv, crashes, ambs, dur,
                 evOf, acked>>

ResolveBlindRebase(n) ==
  /\ fpc[n] = "resolve" /\ ~SettleByFlushId
  /\ hot.ver # lver[n]
  /\ lver' = [lver EXCEPT ![n] = hot.ver]
  /\ lval' = [lval EXCEPT ![n] = hot.val]
  /\ mlog' = [mlog EXCEPT ![n] = [s \in {} |-> <<>>]]
  /\ mlast' = [mlast EXCEPT ![n] = hot.val.last]
  /\ mcomp' = [mcomp EXCEPT ![n] = hot.val.comp]
  /\ march' = [march EXCEPT ![n] = hot.val.arch]
  /\ requeue' = [requeue EXCEPT ![n] = @ \cup pend[n].evs]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ UNCHANGED <<hot, arcv, role, zomb, nextFid, nextEv, crashes, ambs, dur,
                 evOf, acked>>

(***************************************************************************)
(* Crashes.  An in-flight CAS survives its writer and may land late; the   *)
(* SQL revision fences it once another transaction has written.                    *)
(***************************************************************************)
Crash(n) ==
  /\ role[n] = "owner" /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ zomb' = IF fpc[n] \in {"inflight", "resolve"}
               THEN zomb \cup {[reqVer |-> lver[n], val |-> pend[n].val]}
               ELSE zomb
  /\ role' = [role EXCEPT ![n] = "down"]
  /\ fpc' = [fpc EXCEPT ![n] = "idle"]
  /\ pend' = [pend EXCEPT ![n] = NoPend]
  /\ requeue' = [requeue EXCEPT ![n] = {}]
  /\ UNCHANGED <<hot, arcv, lver, lval, mlog, mlast, mcomp, march, nextFid,
                 nextEv, ambs, dur, evOf, acked>>

ZombieApply ==
  /\ \E z \in zomb :
       /\ hot.ver = z.reqVer
       /\ hot' = S3!Applied(hot, z.val)
       /\ FixDur(z.val)
       /\ zomb' = zomb \ {z}
  /\ UNCHANGED <<arcv, role, lver, lval, mlog, mlast, mcomp, march, fpc,
                 pend, requeue, nextFid, nextEv, crashes, ambs, acked>>

ZombieDrop ==
  /\ \E z \in zomb : zomb' = zomb \ {z}
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, march, fpc,
                 pend, requeue, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

OwnerStep ==
  \/ \E n \in Nodes : AppendFresh(n) \/ AppendRequeued(n) \/ Compact(n)
  \/ \E n \in Nodes : ArchiveAppend(n) \/ ArchiveAdvance(n)
  \/ \E n \in Nodes : BeginFlush(n) \/ FlushOk(n) \/ FlushReject(n)
                        \/ FlushRejectResettle(n) \/ ArchiveRebase(n)
  \/ \E n \in Nodes : ResolveLanded(n) \/ ResolveNotLanded(n)
                        \/ ResolveDeposed(n)
  \/ \E n \in Nodes : ResolveBlindRetry(n) \/ ResolveBlindRebase(n)

FaultStep ==
  \/ \E n \in Nodes : FlushAmbApplied(n) \/ FlushAmbLost(n) \/ Crash(n)
                        \/ FlushAmbInFlight(n)
  \/ \E n \in Nodes : ResolveIndeterminate(n)
  \/ ZombieApply \/ ZombieDrop

Next ==
  \/ \E n \in Nodes : Load(n)
  \/ OwnerStep
  \/ FaultStep

Spec == Init /\ [][Next]_vars
FairSpec ==
  Spec
  /\ WF_vars(\E n \in Nodes : Load(n))
  /\ WF_vars(OwnerStep)
  /\ WF_vars(ZombieDrop)

(***************************************************************************)
(* Invariants.                                                             *)
(***************************************************************************)

(* A resident with the current SQL revision must represent that revision. *)
ResidentRevisionSound ==
  \A n \in Nodes :
    (role[n] = "owner" /\ lver[n] = hot.ver) => lval[n] = hot.val

(* The hot window never contradicts what first became durable: a payload  *)
(* or event behind a seq is fixed at its first durability forever.        *)
HotMatchesDurable ==
  \A s \in DOMAIN hot.val.log :
    dur[s] = hot.val.log[s].p /\ evOf[s] = hot.val.log[s].ev

(* One upstream event materializes into at most one durable record.       *)
SingleMaterialization ==
  \A e \in Events : Cardinality({s \in Seqs : evOf[s] = e}) <= 1

(* Deterministic content: the archive object, whoever wrote it, holds     *)
(* exactly the canonical durable records at every position it covers.     *)
ArchiveConvergence ==
  arcv.present =>
    \A i \in 1..Len(arcv.val) :
      /\ dur[i] # 0
      /\ arcv.val[i] = [ev |-> evOf[i], p |-> dur[i]]

(* Nothing below the durable archived watermark is ever unreadable: the   *)
(* one archive object covers it (bytes correct by ArchiveConvergence).    *)
NoRecordLoss ==
  hot.val.arch > 0 => (arcv.present /\ Len(arcv.val) >= hot.val.arch)

(* Single visibility predicate: everything between the watermarks is in   *)
(* the hot window.                                                        *)
WindowComplete ==
  \A s \in Seqs :
    (s > hot.val.arch /\ s <= hot.val.last) => s \in DOMAIN hot.val.log

(* ... and nothing else is: archived records must have left the window.   *)
(* Together with WindowComplete the window is exactly (arch, last] — the  *)
(* PG body range. SQL refinement has separate runtime tests.             *)
WindowExact ==
  \A s \in DOMAIN hot.val.log : s > hot.val.arch /\ s <= hot.val.last

(* Everything confirmed upstream is durable (acked \subseteq durable).    *)
(* The converse direction is legal: a crash between apply and             *)
(* confirmation leaves durable-but-unacked work, closed outside this      *)
(* model by upstream redelivery plus the dedupe ledger.                   *)
AckedIsDurable == \A pr \in acked : dur[pr[1]] = pr[2]

(* Weaker, timing-tolerant check for the ChunkFromMemory witness: once    *)
(* every seq the archive covers is durably settled, its bytes must equal  *)
(* the settled log.  Unlike ArchiveConvergence it stays silent while a    *)
(* buggy early append holds not-yet-durable records, so the violation     *)
(* trace runs on to the second owner whose flush settles the range        *)
(* differently — the divergent-bytes split-owner scene.                   *)
ChunkMatchesSettledLog ==
  (arcv.present /\ \A i \in 1..Len(arcv.val) : dur[i] # 0) =>
    \A i \in 1..Len(arcv.val) :
      arcv.val[i] = [ev |-> evOf[i], p |-> dur[i]]

(* Logical release and physical publication each stay within durability. *)
WatermarkOrder == hot.val.arch <= hot.val.last /\ hot.val.comp <= hot.val.last

(* Fair eligible worker progress and bounded faults drain committed data. *)
(* The abstraction omits the engineering microbatch/idle scheduling cost.  *)
EventuallyArchived ==
  (hot.val.last = MaxSeq) ~> (hot.val.arch = MaxSeq)

=============================================================================
