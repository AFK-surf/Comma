--------------------------- MODULE HeadCommit ---------------------------
(***************************************************************************)
(* The claim / commit / release protocol on the per-agent root object,     *)
(* modeling `SalixStore.Agent` (systems/apps/salix_store/lib/salix_store/  *)
(* agent.ex).  One agent, N contending nodes.  The head object's value is  *)
(* the slice of `SalixStore.Head` the protocol branches on:                *)
(*   [epoch, owner, uuid (commit_uuid), seq (journal_tail.seq)]           *)
(*                                                                         *)
(* Time is deliberately absent: `lease_until` only gates steal             *)
(* eligibility in the code (`claimable?`/`lease_stale?`), so the model     *)
(* makes staleness nondeterministically true — any node may attempt a      *)
(* steal at any moment.  Safety must be carried entirely by the ETag CAS   *)
(* and epoch fencing.  `Agent.renew/2` IS modeled (the runtime keep-alive  *)
(* while session work is busy, docs/release-operations.md): a GET-free   *)
(* conditional PUT of the same value from the                            *)
(* in-memory handle — success bumps only the ETag; a 412 re-read fences or *)
(* drops the handle; an ambiguous outcome resolves by re-read and adopts   *)
(* the live ETag only while epoch+owner still match.                       *)
(* Also unmodeled: `create/4` / `seed/4` /                                 *)
(* `discard_created/1` (pre-claim lifecycle; the model starts post-create  *)
(* and `TypeOK` pins the head present) and `do_claim`'s bounded retry      *)
(* budget — the model retries unboundedly where the code gives up after 5  *)
(* attempts with `:claim_exhausted` and the Server stops; both end with    *)
(* no handle held, so safety is unaffected.                                *)
(*                                                                         *)
(* Ambiguous PUTs (timeout / 5xx, the fake's `:ambiguous_before`/`_after`  *)
(* faults) are modeled per call as two extra outcomes: applied-but-        *)
(* ambiguous and not-applied-but-ambiguous, after which the process        *)
(* enters the code's resolve branch.  A budget (MaxFaults) bounds how      *)
(* many ambiguous outcomes a behavior may contain — this keeps the retry   *)
(* and uuid space finite; safety must hold for every budget.               *)
(*                                                                         *)
(* Ghost variable `log` records every APPLIED commit at the instant the    *)
(* PUT lands (including ambiguous-applied).  The headline invariants:      *)
(*   - LogSeqContiguous: log[i].seq = i — no lost and no double-applied    *)
(*     commit, ever ("a stale owner categorically cannot persist").        *)
(*   - LogEpochMonotone: epochs never regress across the log.              *)
(*   - OwnedEpochUnique: two live handles never share an epoch.            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

CONSTANTS Node,      \* contending nodes, e.g. {n1, n2}
          NoNode,    \* head.owner_node = nil
          MaxEpoch,  \* state-space bound on claims
          MaxSeq,    \* state-space bound on commits
          MaxFaults, \* budget of ambiguous outcomes per behavior
          MaxRenews  \* budget of applied renew writes per behavior:
                     \* renews are the one write class with no
                     \* epoch/seq/fault budget of its own, and an
                     \* unbudgeted renew makes the ETag space unbounded

S3 == INSTANCE S3

\* Contending nodes are interchangeable: symmetry reduction for TLC
\* (safety configs only — symmetry is unsound under liveness checking).
NodeSym == Permutations(Node)

VARIABLES head,     \* the agents/{id}/state.etf.zst cell
          uuidCtr,  \* fresh-uuid source (uuid/0 in agent.ex)
          faults,   \* ambiguous outcomes consumed so far
          renews,   \* applied renew writes consumed so far
          pc,       \* [Node -> program label]
          h,        \* [Node -> commit handle], mirrors %Owned{etag, epoch, next_seq}
          loc,      \* [Node -> in-flight op locals: captured etag/epoch/seq, my uuid]
          log       \* ghost: applied commits, in apply order

vars == <<head, uuidCtr, faults, renews, pc, h, loc, log>>

Labels == {"idle", "c_read", "c_cas", "c_resolve",
           "owned", "m_cas", "m_412", "m_resolve", "r_cas", "r_412",
           "n_resolve"}

Val(e, o, u, s) == [epoch |-> e, owner |-> o, uuid |-> u, seq |-> s]
NoHandle == [etag |-> 0, epoch |-> 0, next |-> 0]
NoLoc == [etag |-> 0, epoch |-> 0, seq |-> 0, uuid |-> 0]

TypeOK ==
  /\ head.present
  /\ head.val.epoch \in 1..MaxEpoch
  /\ head.val.owner \in Node \cup {NoNode}
  /\ head.val.seq \in 0..MaxSeq
  /\ faults \in 0..MaxFaults
  /\ renews \in 0..MaxRenews
  /\ pc \in [Node -> Labels]
  /\ \A n \in Node : pc[n] \in {"owned", "m_cas", "m_412", "m_resolve",
                                "r_cas", "r_412", "n_resolve"} => h[n].epoch >= 1

Init ==
  \* Post-create, released: do_create wrote epoch 1 with the creator as
  \* owner; we start from the released equivalent (owner cleared) so every
  \* ownership stint in the model goes through claim.
  /\ head = S3!Applied(S3!EmptyCell, Val(1, NoNode, 0, 0))
  /\ uuidCtr = 0
  /\ faults = 0
  /\ renews = 0
  /\ pc = [n \in Node |-> "idle"]
  /\ h = [n \in Node |-> NoHandle]
  /\ loc = [n \in Node |-> NoLoc]
  /\ log = <<>>

-----------------------------------------------------------------------------
(* Claim: do_claim -> read_root -> claimable? -> attempt_claim_cas.        *)

StartClaim(n) ==
  /\ pc[n] = "idle"
  /\ pc' = [pc EXCEPT ![n] = "c_read"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, loc, log>>

\* read_root + claimable?.  Staleness is nondeterministic: when another
\* node owns the head, both "lease looks stale -> CAS" and "held ->
\* {:error, {:held_by, ..}} -> Server stops" are possible next states.
\* head.val.epoch < MaxEpoch is a state-space bound, not protocol.
ClaimReadCas(n) ==
  /\ pc[n] = "c_read"
  /\ head.val.epoch < MaxEpoch
  /\ loc' = [loc EXCEPT ![n] = [etag |-> S3!ETag(head), epoch |-> head.val.epoch,
                                seq |-> head.val.seq, uuid |-> 0]]
  /\ pc' = [pc EXCEPT ![n] = "c_cas"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

ClaimReadHeld(n) ==
  /\ pc[n] = "c_read"
  /\ head.val.owner \notin {NoNode, n}   \* lease_stale? chose FALSE
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

\* Bound reached: stop claiming (pure state-space bound).
ClaimReadBound(n) ==
  /\ pc[n] = "c_read"
  /\ head.val.epoch >= MaxEpoch
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

\* attempt_claim_cas, clean success: epoch+1, owner=n, fresh commit_uuid.
ClaimCasOk(n) ==
  /\ pc[n] = "c_cas"
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ uuidCtr' = uuidCtr + 1
  /\ head' = S3!Applied(head, Val(loc[n].epoch + 1, n, uuidCtr', loc[n].seq))
  /\ h' = [h EXCEPT ![n] = [etag |-> S3!ETag(head'), epoch |-> loc[n].epoch + 1,
                            next |-> loc[n].seq + 1]]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, faults, log>>

\* Clean 412: do_claim retries from a fresh read.
ClaimCas412(n) ==
  /\ pc[n] = "c_cas"
  /\ ~S3!CanPutIfMatch(head, loc[n].etag)
  /\ pc' = [pc EXCEPT ![n] = "c_read"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

\* Ambiguous, write landed: resolve_claim_ambiguity via GET-and-check.
ClaimCasAmbApplied(n) ==
  /\ pc[n] = "c_cas"
  /\ faults < MaxFaults
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ faults' = faults + 1
  /\ uuidCtr' = uuidCtr + 1
  /\ head' = S3!Applied(head, Val(loc[n].epoch + 1, n, uuidCtr', loc[n].seq))
  /\ loc' = [loc EXCEPT ![n].uuid = uuidCtr']
  /\ pc' = [pc EXCEPT ![n] = "c_resolve"]
  /\ UNCHANGED <<renews, h, log>>

\* Ambiguous, write lost (also covers the adapter's retry-412-classified-
\* ambiguous case: response lost and the retry saw a conflict).
ClaimCasAmbLost(n) ==
  /\ pc[n] = "c_cas"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ uuidCtr' = uuidCtr + 1
  /\ loc' = [loc EXCEPT ![n].uuid = uuidCtr']
  /\ pc' = [pc EXCEPT ![n] = "c_resolve"]
  /\ UNCHANGED <<renews, head, h, log>>

\* resolve_claim_ambiguity: my uuid + my ownership -> finish_claim (adopt);
\* anything else -> do_claim again from a fresh read.
ClaimResolveAdopt(n) ==
  /\ pc[n] = "c_resolve"
  /\ head.val.uuid = loc[n].uuid /\ head.val.owner = n
  /\ h' = [h EXCEPT ![n] = [etag |-> S3!ETag(head), epoch |-> head.val.epoch,
                            next |-> head.val.seq + 1]]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

ClaimResolveRetry(n) ==
  /\ pc[n] = "c_resolve"
  /\ ~(head.val.uuid = loc[n].uuid /\ head.val.owner = n)
  /\ pc' = [pc EXCEPT ![n] = "c_read"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

-----------------------------------------------------------------------------
(* Commit: do_commit -> cas_commit_root, with resolve_commit_412 and       *)
(* resolve_commit_ambiguity exactly as in agent.ex.                        *)

StartCommit(n) ==
  /\ pc[n] = "owned"
  /\ h[n].next <= MaxSeq
  /\ uuidCtr' = uuidCtr + 1
  /\ loc' = [loc EXCEPT ![n] = [etag |-> h[n].etag, epoch |-> h[n].epoch,
                                seq |-> h[n].next, uuid |-> uuidCtr']]
  /\ pc' = [pc EXCEPT ![n] = "m_cas"]
  /\ UNCHANGED <<renews, head, faults, h, log>>

CommitCasOk(n) ==
  /\ pc[n] = "m_cas"
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ head' = S3!Applied(head, Val(loc[n].epoch, n, loc[n].uuid, loc[n].seq))
  /\ log' = Append(log, [epoch |-> loc[n].epoch, seq |-> loc[n].seq, node |-> n])
  /\ h' = [h EXCEPT ![n] = [etag |-> S3!ETag(head'), epoch |-> loc[n].epoch,
                            next |-> loc[n].seq + 1]]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, uuidCtr, faults>>

CommitCas412(n) ==
  /\ pc[n] = "m_cas"
  /\ ~S3!CanPutIfMatch(head, loc[n].etag)
  /\ pc' = [pc EXCEPT ![n] = "m_412"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, loc, log>>

CommitCasAmbApplied(n) ==
  /\ pc[n] = "m_cas"
  /\ faults < MaxFaults
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ faults' = faults + 1
  /\ head' = S3!Applied(head, Val(loc[n].epoch, n, loc[n].uuid, loc[n].seq))
  /\ log' = Append(log, [epoch |-> loc[n].epoch, seq |-> loc[n].seq, node |-> n])
  /\ pc' = [pc EXCEPT ![n] = "m_resolve"]
  /\ UNCHANGED <<renews, uuidCtr, h, loc>>

CommitCasAmbLost(n) ==
  /\ pc[n] = "m_cas"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ pc' = [pc EXCEPT ![n] = "m_resolve"]
  /\ UNCHANGED <<renews, head, uuidCtr, h, loc, log>>

\* resolve_commit_412, clause order preserved:
\*   1. epoch newer or owner changed        -> {:error, :fenced}
\*   2. commit_uuid mine                    -> adopt_commit
\*   3. otherwise                           -> {:error, {:stale_etag, ..}}
\* Clauses 2 and 3 end differently: adopt continues owning; stale_etag
\* propagates as a cycle error and the Server stops WITHOUT releasing
\* (SalixAgent.Server handle_process_result -> {:stop, {:cycle_error, ..}}).
Commit412Fenced(n) ==
  /\ pc[n] = "m_412"
  /\ head.val.epoch > loc[n].epoch \/ head.val.owner # n
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

Commit412Adopt(n) ==
  /\ pc[n] = "m_412"
  /\ ~(head.val.epoch > loc[n].epoch \/ head.val.owner # n)
  /\ head.val.uuid = loc[n].uuid
  /\ h' = [h EXCEPT ![n] = [etag |-> S3!ETag(head), epoch |-> loc[n].epoch,
                            next |-> loc[n].seq + 1]]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

Commit412Stale(n) ==
  /\ pc[n] = "m_412"
  /\ ~(head.val.epoch > loc[n].epoch \/ head.val.owner # n)
  /\ head.val.uuid # loc[n].uuid
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

\* resolve_commit_ambiguity, clause order preserved:
\*   1. commit_uuid mine and still owner -> adopt_commit
\*   2. epoch newer or owner changed     -> {:error, :fenced}
\*   3. otherwise                        -> {:error, {:ambiguous_unresolved,..}}
CommitResolveAdopt(n) ==
  /\ pc[n] = "m_resolve"
  /\ head.val.uuid = loc[n].uuid /\ head.val.owner = n
  /\ h' = [h EXCEPT ![n] = [etag |-> S3!ETag(head), epoch |-> loc[n].epoch,
                            next |-> loc[n].seq + 1]]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

CommitResolveFenced(n) ==
  /\ pc[n] = "m_resolve"
  /\ ~(head.val.uuid = loc[n].uuid /\ head.val.owner = n)
  /\ head.val.epoch > loc[n].epoch \/ head.val.owner # n
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

CommitResolveUnresolved(n) ==
  /\ pc[n] = "m_resolve"
  /\ ~(head.val.uuid = loc[n].uuid /\ head.val.owner = n)
  /\ ~(head.val.epoch > loc[n].epoch \/ head.val.owner # n)
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

-----------------------------------------------------------------------------
(* Renew: put_root_head_from_memory — one conditional PUT, no prior GET.   *)
(* The written value equals the durable value whenever the ETag matches    *)
(* (only the owner writes the root), so success re-Applies head.val and    *)
(* bumps only the ETag; lease_until is not modeled (time-free).  A 412     *)
(* re-read classifies fenced vs stale_etag; the Server aborts the local    *)
(* runtime and stops on either, so both drop the handle.  An ambiguous     *)
(* outcome resolves by re-read: unchanged epoch+owner adopts the live      *)
(* ETag (covering the applied-under-our-feet case that would otherwise     *)
(* self-fence the retry); anything else is fenced.  The implementation     *)
(* additionally requires the live lease_until to PROVE the extension      *)
(* landed before reporting success — an ownership-intact-but-unextended    *)
(* read returns a retryable :renew_unconfirmed so callers never treat an   *)
(* ambiguous-lost renew as a refreshed lease.  That check is time-domain   *)
(* (this model is time-free); RenewResolveAdopt models only the ETag       *)
(* adoption, which is identical in both outcomes.                          *)

RenewCasOk(n) ==
  /\ pc[n] = "owned"
  /\ renews < MaxRenews
  /\ renews' = renews + 1
  /\ S3!CanPutIfMatch(head, h[n].etag)
  /\ head' = S3!Applied(head, head.val)
  /\ h' = [h EXCEPT ![n].etag = S3!ETag(head')]
  /\ UNCHANGED <<uuidCtr, faults, pc, loc, log>>

\* A failed conditional PUT has no effect, so classifying against the head
\* at action time covers every interleaving of the PUT-fail and the
\* re-read.  Fenced and stale_etag both end with the Server aborting the
\* local runtime and stopping without release.
RenewFencedOrStale(n) ==
  /\ pc[n] = "owned"
  /\ ~S3!CanPutIfMatch(head, h[n].etag)
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, loc, log>>

RenewCasAmbApplied(n) ==
  /\ pc[n] = "owned"
  /\ faults < MaxFaults
  /\ renews < MaxRenews
  /\ renews' = renews + 1
  /\ S3!CanPutIfMatch(head, h[n].etag)
  /\ faults' = faults + 1
  /\ head' = S3!Applied(head, head.val)
  /\ pc' = [pc EXCEPT ![n] = "n_resolve"]
  /\ UNCHANGED <<uuidCtr, h, loc, log>>

RenewCasAmbLost(n) ==
  /\ pc[n] = "owned"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ pc' = [pc EXCEPT ![n] = "n_resolve"]
  /\ UNCHANGED <<renews, head, uuidCtr, h, loc, log>>

RenewResolveAdopt(n) ==
  /\ pc[n] = "n_resolve"
  /\ head.val.epoch = h[n].epoch /\ head.val.owner = n
  /\ h' = [h EXCEPT ![n].etag = S3!ETag(head)]
  /\ pc' = [pc EXCEPT ![n] = "owned"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, loc, log>>

RenewResolveFenced(n) ==
  /\ pc[n] = "n_resolve"
  /\ ~(head.val.epoch = h[n].epoch /\ head.val.owner = n)
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, loc, log>>

-----------------------------------------------------------------------------
(* Release: do_release -> update_root_head.  Any failure (fenced, stale    *)
(* etag, ambiguous "other") is swallowed by the passivating Server         *)
(* (`_ = Agent.release(..)`); the process stops either way.                *)

StartRelease(n) ==
  /\ pc[n] = "owned"
  /\ loc' = [loc EXCEPT ![n] = [etag |-> h[n].etag, epoch |-> h[n].epoch,
                                seq |-> 0, uuid |-> 0]]
  /\ pc' = [pc EXCEPT ![n] = "r_cas"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, log>>

ReleaseCasOk(n) ==
  /\ pc[n] = "r_cas"
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ head' = S3!Applied(head, [head.val EXCEPT !.owner = NoNode])
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, uuidCtr, faults, log>>

ReleaseCas412(n) ==
  /\ pc[n] = "r_cas"
  /\ ~S3!CanPutIfMatch(head, loc[n].etag)
  /\ pc' = [pc EXCEPT ![n] = "r_412"]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, h, loc, log>>

\* update_root_head 412 re-read: fenced -> :ok, else {:error, :stale_etag};
\* the passivating caller ignores both.  Owner field stays as-is (a fenced
\* release leaves the new owner's head untouched — correct).
Release412(n) ==
  /\ pc[n] = "r_412"
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

ReleaseCasAmbApplied(n) ==
  /\ pc[n] = "r_cas"
  /\ faults < MaxFaults
  /\ S3!CanPutIfMatch(head, loc[n].etag)
  /\ faults' = faults + 1
  /\ head' = S3!Applied(head, [head.val EXCEPT !.owner = NoNode])
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, uuidCtr, log>>

ReleaseCasAmbLost(n) ==
  /\ pc[n] = "r_cas"
  /\ faults < MaxFaults
  /\ faults' = faults + 1
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, log>>

-----------------------------------------------------------------------------
(* Crash: the BEAM node (or the Server process) dies between any two S3    *)
(* operations.  Restart re-enters only through claim; locals are gone.     *)
(* The head keeps whatever it said — a dangling owner is exactly the       *)
(* stale-lease takeover case.                                              *)

Crash(n) ==
  /\ pc[n] # "idle"
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ h' = [h EXCEPT ![n] = NoHandle]
  /\ loc' = [loc EXCEPT ![n] = NoLoc]
  /\ UNCHANGED <<renews, head, uuidCtr, faults, log>>

-----------------------------------------------------------------------------
Next ==
  \E n \in Node :
    \/ StartClaim(n) \/ ClaimReadCas(n) \/ ClaimReadHeld(n) \/ ClaimReadBound(n)
    \/ ClaimCasOk(n) \/ ClaimCas412(n)
    \/ ClaimCasAmbApplied(n) \/ ClaimCasAmbLost(n)
    \/ ClaimResolveAdopt(n) \/ ClaimResolveRetry(n)
    \/ StartCommit(n) \/ CommitCasOk(n) \/ CommitCas412(n)
    \/ CommitCasAmbApplied(n) \/ CommitCasAmbLost(n)
    \/ Commit412Fenced(n) \/ Commit412Adopt(n) \/ Commit412Stale(n)
    \/ CommitResolveAdopt(n) \/ CommitResolveFenced(n) \/ CommitResolveUnresolved(n)
    \/ RenewCasOk(n) \/ RenewFencedOrStale(n)
    \/ RenewCasAmbApplied(n) \/ RenewCasAmbLost(n)
    \/ RenewResolveAdopt(n) \/ RenewResolveFenced(n)
    \/ StartRelease(n) \/ ReleaseCasOk(n) \/ ReleaseCas412(n) \/ Release412(n)
    \/ ReleaseCasAmbApplied(n) \/ ReleaseCasAmbLost(n)
    \/ Crash(n)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants.                                                             *)

\* No lost and no double-applied commit: the ghost log is exactly
\* seq 1, 2, 3, ... in apply order.  A stale owner persisting anything, a
\* blind retry of an ambiguous-applied commit, or a wrong adopt would all
\* break contiguity.
LogSeqContiguous == \A i \in 1..Len(log) : log[i].seq = i

\* Epochs never regress across applied commits.
LogEpochMonotone ==
  \A i, j \in 1..Len(log) : i < j => log[i].epoch <= log[j].epoch

\* The live head's seq always equals the number of applied commits.
HeadSeqIsLogLen == head.val.seq = Len(log)

\* Two nodes never both hold a handle for the same epoch.
OwnedLabels == {"owned", "m_cas", "m_412", "m_resolve", "r_cas", "r_412", "n_resolve"}
OwnedEpochUnique ==
  \A n1, n2 \in Node : (n1 # n2 /\ pc[n1] \in OwnedLabels /\ pc[n2] \in OwnedLabels)
    => h[n1].epoch # h[n2].epoch

\* Handle honesty: an unfenced handle (its ETag still names the live head)
\* agrees with the head about ownership, epoch, and next sequence.
HandleHonest ==
  \A n \in Node :
    (pc[n] \in OwnedLabels /\ h[n].etag = S3!ETag(head))
      => /\ head.val.owner = n
         /\ head.val.epoch = h[n].epoch
         /\ h[n].next = head.val.seq + 1

=============================================================================
