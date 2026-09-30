------------------------- MODULE SessionEpochFence -------------------------
(***************************************************************************)
(* Runtime-epoch fencing of the session object                             *)
(* Round.commit_tool_intent may compute trusted replayable reads before   *)
(* CAS. Computation is not a commit or effect authorization in this model.*)
(* InternalSessionStore still fences the frozen owner epoch before CAS.   *)
(* (docs/release-operations.md, D2/D3).               *)
(*                                                                         *)
(* One session object, CAS'd on its ETag, now also carries `runtime_epoch` *)
(* — the agent-root epoch of its last committing owner. Node runners hold  *)
(* monotonically claimed epochs (monotonicity is inherited from the fenced *)
(* root head, modeled in HeadCommit.tla; here claims simply hand out       *)
(* increasing epochs). A runner's commit re-reads the object, refuses with *)
(* a terminal fence when the durable epoch exceeds its own (never a        *)
(* rebase), and otherwise CAS-writes its events WITH its epoch stamped in  *)
(* the same conditional write — so fence check and payload are one atomic  *)
(* CAS with no check-then-write gap.                                       *)
(*                                                                         *)
(* Ghost history records, per committed write, the epoch it landed under.  *)
(* The theorem is the linearization claim of the design:                   *)
(*                                                                         *)
(*   - FenceSafety: once a write of epoch e has landed, no write of a      *)
(*     lower epoch ever lands after it (history is epoch-monotone).        *)
(*   - FencedRunnersStop: a fenced local cell blocks every new dispatch;   *)
(*     only an already-in-flight CAS may still complete, and FenceSafety   *)
(*     shows the ETag serializes it before the takeover stamp.             *)
(*                                                                         *)
(* Discovery is structural rather than a checked liveness property: in the *)
(* safe variant a superseded runner's next Read is its LAST — it lands in  *)
(* `fenced` with no path back except a fresh higher-epoch Claim.           *)
(*                                                                         *)
(* Two expected-violation configs document what the fence does NOT hold    *)
(* against: SessionEpochFence_UnsafeRebase.cfg (RebaseOnEpochRegression =  *)
(* TRUE, the pre-fix 64-retry rebase loop — a superseded node keeps        *)
(* landing writes) and SessionEpochFence_LegacyStrip.cfg                   *)
(* (ModelLegacyWriters = TRUE, the mixed-version deploy window — an old    *)
(* node's struct drops the stamp, so I1 holds only once the fleet is       *)
(* uniformly on stamping code).                                            *)
(*                                                                         *)
(* A runner's `epochOf` is IMMUTABLE once claimed — and the implementation *)
(* honors exactly that shape: each session actor FREEZES the epoch its     *)
(* work runs under into its Registry value at start (or first commit), and *)
(* admission/stamping use that frozen actor-scoped epoch, never the        *)
(* mutable node-wide cell alone.  Without the freeze, a same-node re-claim *)
(* would let a stale in-flight actor adopt the new epoch and launder its   *)
(* write past the fence — a race this model would not exhibit, which is    *)
(* why the binding is part of the modeled contract.                        *)
(*                                                                         *)
(* Code anchors:                                                           *)
(* - SalixAgent.InternalSessionStore.local_runtime_epoch/2 (actor-frozen   *)
(*   epoch via Registry value) + verify_runtime_epoch/3 +                  *)
(*   stamp_runtime_epoch/2 (do_commit / do_commit_dynamic / do_seed)       *)
(* - SalixAgent.ExternalSessionStore.update_state/3                        *)
(* - SalixAgent.InternalSessionActor/ExternalSessionActor init (freeze)    *)
(* - SalixAgent.OwnershipCell (fence/install; local mirror only)           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

CONSTANTS Runners,                 \* runner processes, e.g. {r1, r2}
          MaxEpoch,                \* bound on claims
          MaxWrites,               \* bound on landed writes (ETag space)
          RebaseOnEpochRegression, \* TRUE = pre-fix behavior (unsafe)
          ModelLegacyWriters       \* TRUE = mixed-version deploy window:
                                   \* an old node's read-modify-write strips
                                   \* the epoch field (its struct drops
                                   \* unknown keys), resetting the fence

RunnerSym == Permutations(Runners)

VARIABLES obj,      \* session object: [etag |-> Nat, epoch |-> Nat]
          nextEpoch,\* next epoch a claim hands out
          epochOf,  \* runner -> claimed epoch (0 = none)
          cell,     \* runner -> "owned" | "fenced" | "absent" (local cell)
          snap,     \* runner -> read snapshot [etag, epoch] or <<>>
          pc,       \* runner -> "idle" | "read" | "cas" | "fenced"
          history   \* ghost: sequence of epochs in landed-write order

vars == <<obj, nextEpoch, epochOf, cell, snap, pc, history>>

NoSnap == [etag |-> 0, epoch |-> 0, valid |-> FALSE]

TypeOK ==
  /\ obj \in [etag : 0..MaxWrites, epoch : 0..MaxEpoch]
  /\ nextEpoch \in 1..(MaxEpoch + 1)
  /\ epochOf \in [Runners -> 0..MaxEpoch]
  /\ cell \in [Runners -> {"owned", "fenced", "absent"}]
  /\ snap \in [Runners -> [etag : 0..MaxWrites, epoch : 0..MaxEpoch, valid : BOOLEAN]]
  /\ pc \in [Runners -> {"idle", "read", "cas", "fenced"}]
  /\ history \in Seq(0..MaxEpoch)

Init ==
  /\ obj = [etag |-> 0, epoch |-> 0]
  /\ nextEpoch = 1
  /\ epochOf = [r \in Runners |-> 0]
  /\ cell = [r \in Runners |-> "absent"]
  /\ snap = [r \in Runners |-> NoSnap]
  /\ pc = [r \in Runners |-> "idle"]
  /\ history = <<>>

(* A runner claims the agent root: epochs are handed out monotonically     *)
(* (HeadCommit.tla owns the CAS that guarantees this). Claiming re-owns a  *)
(* previously fenced runner at the new, higher epoch.                      *)
Claim(r) ==
  /\ nextEpoch <= MaxEpoch
  /\ pc[r] \in {"idle", "fenced"}
  /\ epochOf' = [epochOf EXCEPT ![r] = nextEpoch]
  /\ nextEpoch' = nextEpoch + 1
  /\ cell' = [cell EXCEPT ![r] = "owned"]
  /\ pc' = [pc EXCEPT ![r] = "idle"]
  /\ UNCHANGED <<obj, snap, history>>

(* Begin a commit: only an owned, claimed runner dispatches work. The      *)
(* fenced-cell refusal is the local pre-dispatch gate (D3.4).              *)
BeginCommit(r) ==
  /\ pc[r] = "idle"
  /\ epochOf[r] > 0
  /\ cell[r] = "owned"
  /\ pc' = [pc EXCEPT ![r] = "read"]
  /\ UNCHANGED <<obj, nextEpoch, epochOf, cell, snap, history>>

(* Read the object (the read the commit path already performs). A durable  *)
(* epoch above the runner's own is the fence: terminal, and it fences the  *)
(* local cell — no retry, no rebase.                                       *)
Read(r) ==
  /\ pc[r] = "read"
  /\ IF obj.epoch > epochOf[r]
       THEN /\ pc' = [pc EXCEPT ![r] = "fenced"]
            /\ cell' = [cell EXCEPT ![r] = "fenced"]
            /\ snap' = [snap EXCEPT ![r] = NoSnap]
       ELSE /\ pc' = [pc EXCEPT ![r] = "cas"]
            /\ cell' = cell
            /\ snap' = [snap EXCEPT ![r] =
                          [etag |-> obj.etag, epoch |-> obj.epoch, valid |-> TRUE]]
  /\ UNCHANGED <<obj, nextEpoch, epochOf, history>>

(* The conditional write. Success stamps the runner's epoch into the same  *)
(* CAS. An ETag miss re-reads: the fixed path then refuses if the fresh    *)
(* epoch is higher (Read does that check); the unsafe variant lets the     *)
(* re-read rebase regardless — RebaseOnEpochRegression models the old      *)
(* 64-retry loop by sending the loser back to "read" without the epoch     *)
(* check ever terminating it. Concretely the unsafe re-read is modeled by  *)
(* skipping the fence branch.                                              *)
CasOk(r) ==
  /\ pc[r] = "cas"
  /\ snap[r].valid
  /\ obj.etag = snap[r].etag
  /\ obj.etag < MaxWrites
  /\ obj' = [etag |-> obj.etag + 1, epoch |-> epochOf[r]]
  /\ history' = Append(history, epochOf[r])
  /\ snap' = [snap EXCEPT ![r] = NoSnap]
  /\ pc' = [pc EXCEPT ![r] = "idle"]
  /\ UNCHANGED <<nextEpoch, epochOf, cell>>

(* The fixed conflict path re-enters do_commit; the implementation's       *)
(* recursion pays one more GET before verify_runtime_epoch fences on the   *)
(* cell or the durable epoch (both checks precede any write). The model    *)
(* collapses that to: a fenced cell is terminal with no fresh read,        *)
(* otherwise the re-read applies the durable epoch fence — safety-         *)
(* equivalent; the extra fenced-retry GET is an efficiency detail.         *)
CasConflictSafe(r) ==
  /\ ~RebaseOnEpochRegression
  /\ pc[r] = "cas"
  /\ snap[r].valid
  /\ obj.etag # snap[r].etag
  /\ pc' = [pc EXCEPT ![r] = IF cell[r] = "fenced" THEN "fenced" ELSE "read"]
  /\ snap' = [snap EXCEPT ![r] = NoSnap]
  /\ UNCHANGED <<obj, nextEpoch, epochOf, cell, history>>

(* Pre-fix behavior: the conflict handler rebases onto the fresh object    *)
(* without any epoch comparison — the loser adopts the winner's ETag and   *)
(* commits on top, whatever the epochs.                                    *)
CasConflictRebase(r) ==
  /\ RebaseOnEpochRegression
  /\ pc[r] = "cas"
  /\ snap[r].valid
  /\ obj.etag # snap[r].etag
  /\ snap' = [snap EXCEPT ![r] =
                [etag |-> obj.etag, epoch |-> obj.epoch, valid |-> TRUE]]
  /\ pc' = pc
  /\ UNCHANGED <<obj, nextEpoch, epochOf, cell, history>>

(* The takeover nudge / renew fence / abort: a runner whose epoch is below *)
(* the durable one may learn out-of-band at any time. Deliberately weak: a *)
(* CAS already dispatched ("cas" with a snapshot) is NOT cancelled — the   *)
(* HTTP PUT may already be on the wire — so the theorem must hold from the *)
(* ETag serialization alone, never from the nudge. The fenced cell only    *)
(* blocks NEW dispatches (BeginCommit).                                    *)
NudgeFence(r) ==
  /\ epochOf[r] < obj.epoch
  /\ cell[r] # "fenced"
  /\ cell' = [cell EXCEPT ![r] = "fenced"]
  /\ IF pc[r] = "cas"
       THEN /\ pc' = pc
            /\ snap' = snap
       ELSE /\ pc' = [pc EXCEPT ![r] = "fenced"]
            /\ snap' = [snap EXCEPT ![r] = NoSnap]
  /\ UNCHANGED <<obj, nextEpoch, epochOf, history>>

(* Mixed-version deploy window (finding: an old node's State struct has no *)
(* runtime_epoch field, so its read-modify-write CAS re-lands the object   *)
(* with the stamp stripped — read as epoch 0 by every new-code reader).    *)
(* The legacy write itself is unstamped content churn and is not recorded  *)
(* in `history` (which tracks epoch-stamped commits); what it breaks is    *)
(* the fence for everyone AFTER it: a superseded runner's next read sees   *)
(* epoch 0, is not fenced, and lands — the expected FenceSafety            *)
(* counterexample of SessionEpochFence_LegacyStrip.cfg. This is the        *)
(* documented deploy-window caveat: I1 holds only once the fleet is        *)
(* uniformly on stamping code.                                             *)
LegacyStrip ==
  /\ ModelLegacyWriters
  /\ obj.etag < MaxWrites
  /\ obj' = [etag |-> obj.etag + 1, epoch |-> 0]
  /\ UNCHANGED <<nextEpoch, epochOf, cell, snap, pc, history>>

(* The suite runs TLC with -deadlock; states where every budget (epochs,   *)
(* writes) is exhausted are legitimate terminals, not deadlocks.           *)
Done == UNCHANGED vars

Next ==
  \/ \E r \in Runners :
       \/ Claim(r)
       \/ BeginCommit(r)
       \/ Read(r)
       \/ CasOk(r)
       \/ CasConflictSafe(r)
       \/ CasConflictRebase(r)
       \/ NudgeFence(r)
  \/ LegacyStrip
  \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Invariants                                                              *)
(***************************************************************************)

\* Landed writes are epoch-monotone: no lower-epoch write after a higher one.
FenceSafety ==
  \A i, j \in 1..Len(history) : (i < j) => history[i] <= history[j]

\* The durable object's epoch never regresses.
NoObjectEpochRegression ==
  \A i \in 1..Len(history) : history[i] <= obj.epoch

\* A fenced cell blocks every NEW dispatch: a fenced runner is never in
\* "read" (only BeginCommit enters it, and it requires an owned cell). An
\* in-flight CAS may still complete — FenceSafety covers why that is safe.
FencedRunnersStop ==
  \A r \in Runners : cell[r] = "fenced" => pc[r] # "read"

=============================================================================
