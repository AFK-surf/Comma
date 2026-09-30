------------------------- MODULE SessionHotArchive -------------------------
(***************************************************************************)
(* Internal-session storage: hot object and logical archive prefix         *)
(* (docs/storage-search.md).                     *)
(*                                                                         *)
(* The hot object is a single cell holding scalar state plus the live      *)
(* window of log records; every flush is one CAS carrying a fresh          *)
(* flush_id.  An ambiguous CAS (response lost) is settled by reading the   *)
(* object back: exact post-image -> landed; own ETag unchanged -> unknown, *)
(* retain the SAME materialization; a foreign version -> deposed.         *)
(* The model appends summary-covered records to one logical archive.      *)
(* It then advances archived_through through a normal hot-object CAS.     *)
(* Publication is ATOMIC here, and monotonicity is ASSUMED.                *)
(* ArchiveAppend checks conditional monotone publication separately.      *)
(* Its NoFence case must violate the invariant: the write precondition    *)
(* prevents a stale publisher from replacing a longer committed prefix.   *)
(*                                                                         *)
(* Format-3 scope: the hot CAS and read-back pipeline stays unchanged.     *)
(* The single archive value abstracts the published logical prefix.       *)
(* Session/ArchivePublication.lean implements immutable segment creation,  *)
(* adoption, and advance construction. InternalSessionStore executes I/O.  *)
(* The sealer reads one durable revision for publication and its hot CAS. *)
(* A rejected CAS reloads and republishes instead of reusing its advance. *)
(* This model does not prove that implementation's refinement.             *)
(* ArchiveAppend checks conditional monotone publication separately.      *)
(* Historical SessionSegmentSeal references are not current proof evidence.*)
(*                                                                         *)
(* Owners load the hot object and thereafter write from memory; two        *)
(* believers may coexist (lease loss, paused process) and a crashed        *)
(* owner's in-flight CAS may land late — the ETag is the only fence.       *)
(*                                                                         *)
(* The three boolean constants each guard one documented rule; the         *)
(* expected-counterexample configs flip them:                              *)
(*   SettleByFlushId    settle ambiguity by exact post-image; blind        *)
(*                      ETag-refresh retry rematerializes a batch that     *)
(*                      already landed (duplicate records).                *)
(*   CreateBeforeAdvance append lands before the watermark CAS;           *)
(*                      advancing first loses records at the crash point.  *)
(*   LateApplyInFlight  a live owner's ambiguous CAS may still be IN       *)
(*                      FLIGHT: it lands later, after the settlement read.  *)
(*                      The read is therefore not a fence, and the          *)
(*                      same-bytes retry can take a stale 412 for the       *)
(*                      owner's OWN write.  With this enabled, a rejection  *)
(*                      that our own write can explain must re-settle       *)
(*                      instead of deposing — deposing hands the batch back *)
(*                      to the caller, which re-materializes every record   *)
(*                      that carries no dedupe key.  (SalixStore.S3.Fake's  *)
(*                      `:apply_after_next_get` fault is this transition.)  *)
(*   ChunkFromDurable   compaction and the append source read only the     *)
(*                      durable-confirmed log.  The buggy variant treats   *)
(*                      in-memory state as durable in BOTH the compaction  *)
(*                      bound and the append source — one coherent wrong   *)
(*                      worldview.  Its witness is the advertised split-   *)
(*                      owner divergence: owner A archives an unflushed    *)
(*                      record, owner B loads the durable log, appends a   *)
(*                      different record at the same seq and flushes —     *)
(*                      the settled log now contradicts the archived bytes *)
(*                      (ChunkMatchesSettledLog).                          *)
(*                                                                         *)
(* Records are immutable from first durability by design (redaction is a  *)
(* state-level overlay in the hot object, never a byte rewrite), so the   *)
(* model's freeze of dur/evOf at first durability IS the documented       *)
(* contract, not a strengthening.                                          *)
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
(* Unlike the hot object it carries no version: the implementation CASes   *)
(* on the ETag, but nothing here reads it and the append-only construction *)
(* (the durable prefix is carried over verbatim) already gives the         *)
(* guarantee the ETag provides.  Keeping a counter would only split states *)
(* that hold identical bytes by how many appends produced them — the same  *)
(* content reached as 1+1 or as one 2 is the same object.                  *)
ArchiveApplied(v) == [present |-> TRUE, val |-> v, ver |-> 0]

VARIABLES hot,      \* S3 cell: val = [last, arch, comp, fid, log]
          arcv,     \* the ONE archive object: a cell holding a log prefix
          role,     \* [Nodes -> {"down","owner"}]
          lver,     \* [Nodes -> Nat] ETag of the durable-confirmed base
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
(* Archive step 1: APPEND to the ONE archive object, up to the compaction  *)
(* watermark.  There is no packing rule to hold records back, so the       *)
(* append covers exactly what the summary now covers.  The object is the   *)
(* authority on what is already durable: the writer extends it and never   *)
(* rebuilds or shortens it, so a stale owner cannot roll it back and a     *)
(* lost advance is resumed by appending only the gap.                      *)
(***************************************************************************)
ArchiveAppend(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle"
  /\ LET src    == IF ChunkFromDurable THEN lval[n].log ELSE Full(n)
         target == mcomp[n]
         have   == Len(arcv.val)
     IN (* The object already reaching the watermark is not a no-op to fix
           up: it is either our own landed append or another owner's longer
           one, and either way it must NOT be rewritten.  A stale owner
           whose target is below the object's end therefore does nothing. *)
        /\ target > have
        (* Only the GAP has to be in the window.  Records at or below the
           object's end have already been archived out of it — requiring the
           whole prefix here is what wedged archival after the first
           advance (liveness counterexample, 2026-08-09). *)
        /\ \A i \in (have + 1)..target : i \in DOMAIN src
        (* Append-only: the durable prefix is carried over verbatim, never
           re-derived from a view that may be stale. *)
        /\ arcv' = ArchiveApplied(
                     [i \in 1..target |->
                        IF i <= have THEN arcv.val[i] ELSE src[i]])
  /\ UNCHANGED <<hot, role, lver, lval, mlog, mlast, mcomp, march, fpc, pend,
                 requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

(* Archive step 2: adopt the advanced watermark in memory; it becomes     *)
(* durable through a normal flush, which also drops the archived records  *)
(* from the hot window.  The safe order gates this on the archive object  *)
(* already holding the records.                                          *)
ArchiveAdvance(n) ==
  /\ role[n] = "owner" /\ fpc[n] = "idle"
  /\ mcomp[n] > march[n]
  /\ CreateBeforeAdvance => Len(arcv.val) >= mcomp[n]
  /\ march' = [march EXCEPT ![n] = mcomp[n]]
  /\ UNCHANGED <<hot, arcv, role, lver, lval, mlog, mlast, mcomp, fpc, pend,
                 requeue, zomb, nextFid, nextEv, crashes, ambs, dur, evOf,
                 acked>>

(***************************************************************************)
(* The flush: one CAS on the hot object.                                   *)
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
  /\ lver' = [lver EXCEPT ![n] = hot'.ver]
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
  /\ ~OwnWriteExplains(n)
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

(***************************************************************************)
(* Ambiguity settlement: read the hot object back.                         *)
(* Safe rule: exact post-image -> landed; own ETag -> retry the            *)
(* SAME pend (one flush_id, one materialization); else deposed.            *)
(* Blind rule (violation): compare ETags only and rebase on any change,    *)
(* requeueing the batch — which duplicates it when the write had landed.   *)
(***************************************************************************)
(* The design settles the landed branch by byte-exact post-image compare, *)
(* not by flush_id alone; the extra conjunct is that comparison.  In the  *)
(* model fid uniqueness makes it provably redundant — checking it keeps   *)
(* the written rule, and a divergence would fail the guard, not pass it.  *)
ResolveLanded(n) ==
  /\ fpc[n] = "resolve" /\ SettleByFlushId
  /\ hot.val.fid = pend[n].fid /\ hot.val = pend[n].val
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
(* ETag is what fences it once anyone else has written.                    *)
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
                        \/ FlushRejectResettle(n)
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
(* bounded-hot-object guarantee.  Retaining history would violate this.   *)
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

(* Watermark order from the doc: archived_through <= compacted_through.   *)
WatermarkOrder == hot.val.arch <= hot.val.comp /\ hot.val.comp <= hot.val.last

(* Under fair owner progress, bounded faults, and a full compaction        *)
(* watermark, everything compacted is eventually archived.                *)
EventuallyArchived ==
  (hot.val.comp = MaxSeq) ~> (hot.val.arch = MaxSeq)

=============================================================================
