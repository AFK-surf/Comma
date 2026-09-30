----------------------------- MODULE ArchiveAppend -----------------------------
(***************************************************************************)
(* The internal-session archive append protocol                            *)
(* (docs/storage-search.md, 归档).                *)
(*                                                                         *)
(* `SessionHotArchive` models the TWO-OBJECT protocol and its crash        *)
(* matrix, and it takes archive monotonicity as given.  This spec is where *)
(* that assumption is discharged: it models the mechanism the              *)
(* implementation actually uses to establish it —                          *)
(*                                                                         *)
(*   1. read the archive object, capturing its body length AND its ETag;   *)
(*   2. decide what to append from the captured view;                      *)
(*   3. conditionally PUT under that ETag (`if_match`).                    *)
(*                                                                         *)
(* Between (1) and (3) another owner may append and advance the durable    *)
(* watermark.  The captured view is then stale, and the whole question is  *)
(* whether the write can roll the object back.  Modeling the append as one *)
(* atomic step that reads the CURRENT object would assume the answer, so   *)
(* the capture is an explicit variable here and the PUT is conditional.    *)
(*                                                                         *)
(* `EtagFence = FALSE` disables the precondition — the unconditional       *)
(* overwrite that `InternalSessionStore` shipped in #798's first cut.  Its *)
(* config is an expected counterexample: it MUST reproduce the             *)
(* stale-owner rollback (archive shortened below the committed watermark), *)
(* and a pass there means the fence stopped being load-bearing.            *)
(*                                                                         *)
(* Records are modeled by their seq alone: what is at risk here is the     *)
(* RANGE the object holds, not record content (byte-level convergence is   *)
(* `ArchiveConvergence` in SessionHotArchive).  So the object's value is   *)
(* the sequence 1..n and `Len` is its coverage.                            *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Nodes, MaxSeq, MaxAmb, EtagFence

ASSUME MaxSeq \in Nat /\ MaxSeq > 0
ASSUME MaxAmb \in Nat
ASSUME EtagFence \in BOOLEAN

S3 == INSTANCE S3

Seqs == 0..MaxSeq
NoBase == [ver |-> -1, len |-> -1, pres |-> FALSE]

VARIABLES
  arcv,      \* the ONE archive object
  comp,      \* durable compacted_seq: monotone, the ceiling on archiving
  committed, \* durable archived_through (the hot object's watermark)
  high,      \* high-water mark of archive coverage: never allowed to drop
  myArch,    \* [Nodes -> Seqs]  each owner's CAPTURED view of committed
  tgt,       \* [Nodes -> Seqs]  each owner's compacted_seq (its append target)
  base,      \* [Nodes -> capture] the archive view+ETag this owner read
  ambs       \* ambiguous-write budget

vars == <<arcv, comp, committed, high, myArch, tgt, base, ambs>>

Capture == [ver : Nat, len : Seqs, pres : BOOLEAN] \cup {NoBase}

TypeOK ==
  /\ arcv.ver \in Nat
  /\ comp \in Seqs
  /\ committed \in Seqs
  /\ high \in Seqs
  /\ myArch \in [Nodes -> Seqs]
  /\ tgt \in [Nodes -> Seqs]
  /\ base \in [Nodes -> Capture]
  /\ ambs \in 0..MaxAmb

Init ==
  /\ arcv = S3!EmptyCell
  /\ comp = 0
  /\ committed = 0
  /\ high = 0
  /\ myArch = [n \in Nodes |-> 0]
  /\ tgt = [n \in Nodes |-> 0]
  /\ base = [n \in Nodes |-> NoBase]
  /\ ambs = 0

(***************************************************************************)
(* Compaction: the durable ceiling on what may be archived.  It only ever  *)
(* advances — an owner's target can be STALE but never invented.           *)
(***************************************************************************)
Compact ==
  /\ comp < MaxSeq
  /\ comp' = comp + 1
  /\ UNCHANGED <<arcv, committed, high, myArch, tgt, base, ambs>>

(***************************************************************************)
(* Reading the session: the owner picks up the durable watermarks AS THEY  *)
(* ARE NOW.  Both may move afterwards, which is exactly what makes the     *)
(* capture stale.  Any earlier archive capture is void.                    *)
(***************************************************************************)
CaptureSession(n) ==
  /\ myArch' = [myArch EXCEPT ![n] = committed]
  /\ tgt' = [tgt EXCEPT ![n] = comp]
  /\ base' = [base EXCEPT ![n] = NoBase]
  /\ UNCHANGED <<arcv, comp, committed, high, ambs>>

(***************************************************************************)
(* Step 1: GET the archive object, capturing length AND ETag together.     *)
(***************************************************************************)
ReadArchive(n) ==
  /\ base[n] = NoBase
  (* The GET yields presence, length and ETag together — that triple IS   *)
  (* the owner's whole basis for the write.                                *)
  /\ base' = [base EXCEPT ![n] =
        [ver |-> arcv.ver, len |-> Len(arcv.val), pres |-> arcv.present]]
  /\ UNCHANGED <<arcv, comp, committed, high, myArch, tgt, ambs>>

(* What the captured view says about the write. *)
Incomplete(n) == base[n].len < myArch[n]
Ahead(n)      == base[n].len > tgt[n]
Nothing(n)    == base[n].len = tgt[n]

(***************************************************************************)
(* The two aborts.  Both are decided from the CAPTURED view, exactly as    *)
(* `adopted_suffix/4` decides them, and both clear the capture so a retry  *)
(* must re-read.                                                           *)
(***************************************************************************)
AbortIncomplete(n) ==
  /\ base[n] # NoBase /\ Incomplete(n)
  /\ base' = [base EXCEPT ![n] = NoBase]
  /\ UNCHANGED <<arcv, comp, committed, high, myArch, tgt, ambs>>

AbortAhead(n) ==
  /\ base[n] # NoBase /\ Ahead(n)
  /\ base' = [base EXCEPT ![n] = NoBase]
  /\ UNCHANGED <<arcv, comp, committed, high, myArch, tgt, ambs>>

(***************************************************************************)
(* Step 3: the conditional PUT.  The body is derived from the CAPTURED     *)
(* view (1..tgt[n]) — a stale owner therefore proposes a SHORTER object    *)
(* than one already durable, and only the ETag precondition stops it.      *)
(***************************************************************************)
Writable(n) == base[n] # NoBase /\ ~Incomplete(n) /\ ~Ahead(n) /\ ~Nothing(n)

(* Which precondition the write carries is decided by the CAPTURED view,  *)
(* exactly as `publish_archive/4` decides it: an object the owner did not  *)
(* see is created (`if_none_match`), one it did see is extended under the  *)
(* ETag it read (`if_match`).                                             *)
(*                                                                        *)
(* `EtagFence` gates ONLY the existing-object branch.  Disabling both      *)
(* would let TLC satisfy the negative config with a first-create race —    *)
(* a real but different defect, reachable before any watermark is          *)
(* committed, so it never exhibits the rollback-below-the-watermark this   *)
(* config exists to witness.  create-once therefore stays on always.       *)
FenceHolds(n) ==
  IF base[n].pres
    THEN (~EtagFence) \/ S3!CanPutIfMatch(arcv, base[n].ver)
    ELSE S3!CanPutIfNoneMatch(arcv)

(* The object as this owner would write it. *)
Body(n) == [i \in 1..tgt[n] |-> i]

ApplyPut(n) ==
  /\ arcv' = S3!Applied(arcv, Body(n))
  /\ high' = IF tgt[n] > high THEN tgt[n] ELSE high

PutOk(n) ==
  /\ Writable(n) /\ FenceHolds(n)
  /\ ApplyPut(n)
  /\ base' = [base EXCEPT ![n] =
        [ver |-> arcv'.ver, len |-> tgt[n], pres |-> TRUE]]
  /\ UNCHANGED <<comp, committed, myArch, tgt, ambs>>

(* 412: the object moved under us.  The caller does NOT retry in place —   *)
(* it drops the capture and the next compaction re-reads.                  *)
PutPreconditionFailed(n) ==
  /\ Writable(n) /\ ~FenceHolds(n)
  /\ base' = [base EXCEPT ![n] = NoBase]
  /\ UNCHANGED <<arcv, comp, committed, high, myArch, tgt, ambs>>

(* Ambiguous transport: the write may or may not have landed. *)
PutAmbiguous(n) ==
  /\ Writable(n) /\ ambs < MaxAmb
  /\ ambs' = ambs + 1
  /\ base' = [base EXCEPT ![n] = NoBase]
  /\ \/ /\ FenceHolds(n)
        /\ ApplyPut(n)
        /\ UNCHANGED <<comp, committed, myArch, tgt>>
     \/ /\ UNCHANGED <<arcv, high, comp, committed, myArch, tgt>>

(***************************************************************************)
(* The hot-object CAS that publishes the watermark.  Its reducer drops a   *)
(* stale advance, so the durable watermark only ever moves forward.        *)
(***************************************************************************)
CommitAdvance(n) ==
  /\ base[n] # NoBase
  /\ ~Incomplete(n)
  (* Equality, not >=: an object longer than this owner's target is the     *)
  (* `archive_ahead` abort in the runtime, which never reaches the advance. *)
  /\ base[n].len = tgt[n]
  /\ committed' = IF tgt[n] > committed THEN tgt[n] ELSE committed
  /\ UNCHANGED <<arcv, comp, high, myArch, tgt, base, ambs>>

Next ==
  \/ Compact
  \/ \E n \in Nodes :
    \/ CaptureSession(n)
    \/ ReadArchive(n)
    \/ AbortIncomplete(n)
    \/ AbortAhead(n)
    \/ PutOk(n)
    \/ PutPreconditionFailed(n)
    \/ PutAmbiguous(n)
    \/ CommitAdvance(n)

Spec == Init /\ [][Next]_vars

(* Fairness on the PROGRESS steps specifically.  Weak fairness on `Next`   *)
(* alone is satisfied by an owner that re-reads forever without ever       *)
(* writing, which says nothing about the protocol.                         *)
FairSpec ==
  /\ Spec
  (* An owner keeps picking the session back up — that is what makes it     *)
  (* notice a compaction watermark that moved while it was idle.            *)
  /\ WF_vars(\E n \in Nodes : CaptureSession(n))
  /\ WF_vars(\E n \in Nodes : ReadArchive(n))
  (* STRONG fairness: a fresh session capture clears the archive capture,   *)
  (* so the write is repeatedly enabled and disabled rather than            *)
  (* continuously enabled.  Weak fairness would let an owner re-read        *)
  (* forever and never write.                                              *)
  /\ SF_vars(\E n \in Nodes : PutOk(n))
  /\ SF_vars(\E n \in Nodes : CommitAdvance(n))

(***************************************************************************)
(* THE property this spec exists for: the archive object never gets        *)
(* shorter than its own high-water mark.  Shortening it deletes committed  *)
(* history that has already left every hot window.                         *)
(***************************************************************************)
NeverShrinks == Len(arcv.val) = high

(* And the watermark never claims more than the object holds. *)
CommittedIsDurable == Len(arcv.val) >= committed

(* Under fair progress every owner's target eventually reaches the object. *)
EventuallyArchived == (comp = MaxSeq) ~> (Len(arcv.val) >= MaxSeq)

=============================================================================
