---------------------------- MODULE RpcDeliver ----------------------------
(***************************************************************************)
(* The A2 rpc-direct delivery handshake (docs/salix/conversation-owner-actor.md *)
(* and `SalixAgent.deliver/3` in `:rpc` mode): a caller resolves placement,*)
(* the resolved node reads the durable agent head as its owner fence       *)
(* (`AgentActor.verify_rpc_delivery_owner/1`), dedupes on the session's    *)
(* `input_dedupe` ledger, and commits the queue append with a session-     *)
(* object CAS (`InternalSessionStore.commit/4`, reload-and-retry on        *)
(* conflict).  The caller acks only on a reply; a lost reply or timeout    *)
(* means a SAME-ID retry against a freshly resolved placement.  A          *)
(* `:not_owner` refusal re-resolves placement INSIDE the facade call,      *)
(* bounded at 2 attempts (`rpc_stage_attempts/4`) — modeled as `hops`,     *)
(* distinct from the caller's own retry budget (`tries`).  The Staged      *)
(* writer is historical: the staged path, its switch, and the absorb       *)
(* engine are all deleted (§3.2 step 4 + §3.4, residue drained to zero).   *)
(* The action is kept as an intentional over-approximation — a ghost       *)
(* ledger-converging second writer — so the invariants keep holding under  *)
(* strictly more interference than the shipped system can produce.  The    *)
(* action models a writer that consults the ledger, i.e. every pod runs    *)
(* ledger-aware code and only the mode differs; the code-version rolling   *)
(* window in which pre-#870 pods append to the external store without a   *)
(* ledger is OUT of this model and documented as a status-quo residual in  *)
(* the plan (§1.1.1 residual 1).                                           *)
(*                                                                         *)
(* Since #870 external-runtime agents run this same protocol as a second   *)
(* instance: their ledger is the `input_dedupe` field of the session's     *)
(* `state.json`, committed by the same single-object CAS as the queue      *)
(* append (`ExternalSessionStore.stage_delivery`).  One mapping note: the  *)
(* external store answers a CAS conflict to its caller as                  *)
(* `:stale_external_session_state` instead of reloading in place — the     *)
(* reload-and-recheck edge the model takes after a conflict corresponds    *)
(* there to the caller's mandated same-id retry re-entering the stage at   *)
(* a fresh read, which re-checks the ledger before any write.  Session-    *)
(* less payloads are resolved at deliver time by the role actor (#871):    *)
(* a router rewrites onto its persisted canonical session before the       *)
(* modeled stage; a role that cannot resolve one is rejected before        *)
(* placement — neither takes a staged path in :rpc mode.  The schedule-    *)
(* side terminal outcome for the rejected class is modeled in              *)
(* ScheduleDispatch.tla (the "undeliverable" disposition).                 *)
(*                                                                         *)
(* The fence is genuinely TWO steps here: FenceRead records the            *)
(* observation (`fenceObs`), and CommitCAS trusts only that recorded       *)
(* observation — an ownership move between the two is a real interleaving, *)
(* not a hand-written shortcut action.                                     *)
(*                                                                         *)
(* What this spec checks (safety only; single message id — the retry and   *)
(* duplication structure is per-id):                                       *)
(*                                                                         *)
(*   - ExactlyOnceDurable: the id lands in the durable queue at most once, *)
(*     under response loss, same-id retries, ownership moves, stale        *)
(*     placement, bounded not_owner re-resolution, concurrent staged+rpc   *)
(*     writers, and 412-reload-retry.  This holds WITHOUT the fence: it    *)
(*     rests on the ledger dedupe being re-checked after every CAS reload. *)
(*   - AckImpliesDurable: an acked delivery is durably appended (plan      *)
(*     §1.6: ok only after the durable commit or a ledger hit).            *)
(*                                                                         *)
(* What the fence buys, honestly:                                          *)
(*   - NoStaleCommit is NOT an invariant of the fenced protocol: the trace *)
(*     FenceRead(passed) ; MoveOwner ; CommitCAS lands one stale commit    *)
(*     (RpcDeliver_FenceResidual.cfg — the SHIPPED exposure).  The         *)
(*     exposure is bounded: the stale commit is a correct, deduped,        *)
(*     durable append; the hazard is only that the new owner's loaded      *)
(*     image misses it until its next conflict-reload or cold load, and    *)
(*     the queue entry is mark-first durable state the session work        *)
(*     projection can enumerate for a wake.  Without the fence the same    *)
(*     counterexample needs no race window at all — one stale placement    *)
(*     resolution suffices (RpcDeliver_NoFence.cfg), which is what the     *)
(*     #843 review reproduced through the public API.                      *)
(*                                                                         *)
(* Removing the ledger dedupe (RpcDeliver_NoDedupe.cfg, Staged=FALSE so    *)
(* the counterexample must be the rpc protocol itself: applied commit,     *)
(* lost response, same-id caller retry, second applied commit) breaks      *)
(* ExactlyOnceDurable — the concrete reason the external store had to     *)
(* gain its own ledger (#870) before external runtimes could enter `:rpc`. *)
(*                                                                         *)
(* The runtime-flip race (#843 owner repro) is a modeled dimension:        *)
(* FlipRuntime rebinds the agent internal -> external mid-call.  The       *)
(* runtime fence is TWO steps, exactly like the owner fence:               *)
(* StageRouteRead records the routing observation (refusing an internal-   *)
(* classified entry that reads "ext" — :runtime_changed), and StageCommit  *)
(* trusts only the recorded observation.  Shipped behavior re-classifies   *)
(* ONCE inside the same deadline (Reclassify = TRUE) and AckImpliesDurable *)
(* holds; Reclassify = FALSE (RpcDeliver_NoReclassify.cfg) models the      *)
(* retired staged-inbox detour that acked with no session commit.  A flip  *)
(* BETWEEN route read and commit is a real interleaving the fence cannot   *)
(* close (two objects, no cross-object atomicity — the north star forbids  *)
(* building it): the commit lands durably in the runtime the agent just    *)
(* left and the ack stands — AckMatchesRuntime's expected violation        *)
(* (RpcDeliver_LateFlipResidual.cfg), the SHIPPED cross-store exposure,    *)
(* contained as documented in plan §1.1.1.                                 *)
(***************************************************************************)
(* Router log admission maps one committed target source position to this *)
(* per-id abstraction. Command.conversationInput publishes source progress *)
(* together with input. Direct-log staging can prepare activation before  *)
(* this same CAS; working-state computation is a stuttering step here.    *)
(* in the same Session CAS as the input queue. Notifications, ordered scans, *)
(* and binding floors are runtime-test boundaries, with no liveness claim. *)
EXTENDS Naturals, S3

CONSTANTS
  Nodes,        \* the two candidate owner nodes
  Fence,        \* BOOLEAN: verify_rpc_delivery_owner enabled
  Dedupe,       \* BOOLEAN: the input_dedupe ledger check enabled
  Staged,       \* BOOLEAN: a concurrent staged writer exists — historical
                \* since §3.4 (engine deleted, residue zero); kept as an
                \* over-approximating ghost writer
  Reclassify,   \* BOOLEAN: :runtime_changed re-classifies once in-deadline
                \* (shipped, #870 round 2); FALSE models the retired
                \* staged-inbox detour that acked at inbox durability only
  SessionAuthority, \* BOOLEAN: the stage resolves an existing session to its
                \* BIRTH store before any agent-record read (shipped, #873
                \* round 5); FALSE is the retired agent-record routing that
                \* split one session id across both stores after a flip
  BirthAuthority, \* BOOLEAN: NEW-session placement claims the per-session
                \* create-once birth marker before any store create
                \* (shipped, #873 round 6); FALSE is the retired behavior
                \* where each first-delivery writer created on its own
                \* admission read — concurrent first deliveries astride a
                \* flip fabricated the id in both stores
  ProbeAuthority, \* BOOLEAN: the birth claim runs only after BOTH stores
                \* CONFIRMED not-found (shipped, #873 round 7 fail-closed
                \* ruling); FALSE is the retired behavior that read a
                \* transient probe ERROR as absence — one 503 on the old
                \* side re-birthed a legacy markerless session across
  StoreGuard,   \* BOOLEAN: the birth claim is enforced INSIDE the store's
                \* create primitives, so every creator — routed deliveries,
                \* the direct external-runtime facade, fork/seed — passes
                \* it (shipped, #873 round 8); FALSE retires the store
                \* guard: an unrouted creator writes on its own side,
                \* ignoring the marker (the round-8 bypass repros)
  StrictWritable, \* BOOLEAN: NEW-input admission to an externally-born
                \* session requires the CURRENT binding — a minted
                \* capability is not a licence for new work after the
                \* binding leaves (shipped, #873 round 9); FALSE retires
                \* the strict check: the capability escape admits new
                \* input to a rebound session (the round-9 P1-2 repro)
  RetryLimit,   \* caller same-id retry budget (timeout/error driven)
  HopLimit,     \* facade stage attempts per call (rpc_stage_attempts: 2)
  MaxMoves      \* ownership move budget (finite state)

VARIABLES
  session,      \* S3 cell: val = [n |-> appended count for THE id]
  mem,          \* per-node loaded image: [etag, n, loaded]
  headOwner,    \* durable agent head owner (moves via lease claim)
  placement,    \* what the ring answers right now (may lag headOwner)
  runtime,      \* the agent's runtime kind: "int", flips (at most once,
                \* via FlipRuntime) to "ext" — the #843 owner-reproduced race
  caller,       \* [pc, target, tries, hops, fenceObs, routeObs, staged,
                \*  req, recl]
  commitRuntime,\* ghost: the runtime kind the applied commit landed in
                \* (= the committed SESSION's runtime, fixed at its birth)
  executedOn,   \* ghost: the runtime kind the post-commit wake ran on
  laterStore,   \* ghost: the store a LATER same-session delivery landed in
  birthMarker,  \* the create-once marker's recorded side ("none" = unclaimed)
  birthStores,  \* the set of stores holding a session with THE id (real
                \* commits and creators update it — not ghost-only)
  extBindingCurrent, \* the externally-born session's binding still matches
                \* the agent record (Rebind flips it off)
  extLateInput, \* outcome of a NEW input arriving after the binding left
  moves,        \* ownership moves consumed
  staleCommits  \* history: commits applied by a non-owner node

NotLoaded == [etag |-> 0, n |-> 0, loaded |-> FALSE]

vars == <<session, mem, headOwner, placement, runtime, caller,
          commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

TypeOK ==
  /\ session.val \in [n: 0..2, sourceFrontier: 0..1]
  /\ headOwner \in Nodes
  /\ placement \in Nodes
  /\ runtime \in {"int", "ext"}
  /\ caller.pc \in {"idle", "inflight", "acked", "gaveup"}
  /\ caller.tries \in 0..RetryLimit
  /\ caller.hops \in 0..(HopLimit - 1)
  /\ caller.target \in Nodes
  /\ caller.fenceObs \in {"none", "passed"}
  /\ caller.staged \in BOOLEAN
  /\ caller.req \in {"int", "ext"}
  /\ caller.recl \in BOOLEAN
  /\ caller.routeObs \in {"none", "done"}
  /\ commitRuntime \in {"none", "int", "ext"}
  /\ executedOn \in {"none", "int", "ext"}
  /\ laterStore \in {"none", "int", "ext"}
  /\ birthMarker \in {"none", "int", "ext"}
  /\ birthStores \subseteq {"int", "ext"}
  /\ extBindingCurrent \in BOOLEAN
  /\ extLateInput \in {"none", "admitted", "refused"}
  /\ moves \in 0..MaxMoves
  /\ staleCommits \in 0..3

Init ==
  /\ session = [present |-> TRUE, val |-> [n |-> 0, sourceFrontier |-> 0], ver |-> 1]
  /\ mem = [nd \in Nodes |-> NotLoaded]
  /\ headOwner \in Nodes
  /\ placement = headOwner
  /\ runtime = "int"
  /\ caller = [pc |-> "idle", target |-> headOwner, tries |-> 0,
               hops |-> 0, fenceObs |-> "none", routeObs |-> "none",
               staged |-> FALSE, req |-> "int", recl |-> FALSE]
  /\ commitRuntime = "none"
  /\ executedOn = "none"
  /\ laterStore = "none"
  /\ birthMarker = "none"
  \* {} = a genuinely new id; a singleton = a LEGACY session born before the
  \* marker deploy (markerless: birthMarker stays "none" for it) — the
  \* round-7 initial condition.
  /\ birthStores \in {{}, {"int"}, {"ext"}}
  /\ extBindingCurrent = TRUE
  /\ extLateInput = "none"
  /\ moves = 0
  /\ staleCommits = 0

(* Ownership moves to the other node (a new Server claims the head).  The  *)
(* claimant's memory image resets: a fresh owner loads before acting.  The *)
(* in-flight caller's recorded fence observation is deliberately NOT       *)
(* touched — that is the residual window.                                  *)
MoveOwner ==
  /\ moves < MaxMoves
  /\ \E nd \in Nodes \ {headOwner}:
       /\ headOwner' = nd
       /\ mem' = [mem EXCEPT ![nd] = NotLoaded]
  /\ moves' = moves + 1
  /\ UNCHANGED <<session, placement, runtime, caller, commitRuntime,
                 executedOn, staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The ring catches up to the durable head.                                *)
SyncPlacement ==
  /\ placement # headOwner
  /\ placement' = headOwner
  /\ UNCHANGED <<session, mem, headOwner, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The caller starts (or same-id-retries) a delivery against whatever the  *)
(* ring answers RIGHT NOW.  A fresh call resets the facade-internal hop    *)
(* budget and the fence observation.                                       *)
CallerSend ==
  /\ caller.pc = "idle"
  /\ caller' = [caller EXCEPT !.pc = "inflight", !.target = placement,
                              !.hops = 0, !.fenceObs = "none",
                              !.routeObs = "none", !.staged = FALSE,
                              !.req = runtime, !.recl = FALSE]
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* Response loss / timeout: the ambiguity row (plan §1.8).  The commit may *)
(* or may not have landed; the caller retries the SAME id or gives up.     *)
CallerTimeout ==
  /\ caller.pc = "inflight"
  /\ \/ /\ caller.tries < RetryLimit
        /\ caller' = [caller EXCEPT !.pc = "idle", !.tries = @ + 1]
     \/ caller' = [caller EXCEPT !.pc = "gaveup"]
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The target node loads the session image (once per activation; a 412     *)
(* reload re-enters here).                                                 *)
NodeLoad(nd) ==
  /\ mem[nd].loaded = FALSE
  /\ mem' = [mem EXCEPT ![nd] =
       [etag |-> ETag(session), n |-> session.val.n, loaded |-> TRUE]]
  /\ UNCHANGED <<session, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* Step one of the fence: the target reads the durable head.  Owner match  *)
(* records the observation; a mismatch answers :not_owner, and the facade  *)
(* re-resolves placement in place (hops) until the bounded budget is       *)
(* spent, after which the error surfaces to the caller's own retry.        *)
FenceRead ==
  /\ caller.pc = "inflight"
  /\ Fence
  /\ caller.fenceObs = "none"
  /\ IF headOwner = caller.target
     THEN caller' = [caller EXCEPT !.fenceObs = "passed"]
     ELSE IF caller.hops + 1 < HopLimit
          \* rpc_stage_attempts: attempt hops+1 refused, re-resolve in place.
          THEN caller' = [caller EXCEPT !.target = placement, !.hops = @ + 1]
          \* Final attempt refused: :not_owner surfaces to the CALLER, whose
          \* own retry budget is consumed — no free restart loop.
          ELSE IF caller.tries < RetryLimit
               THEN caller' = [caller EXCEPT !.pc = "idle", !.tries = @ + 1]
               ELSE caller' = [caller EXCEPT !.pc = "gaveup"]
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* Duplicate hit on the loaded ledger: reply :duplicate, no write.  The    *)
(* code path runs after the fence; the reply itself may still be lost.    *)
(* Internal Command.duplicateInput also fences a working-ledger hit. This *)
(* action starts from loaded durable facts, so it needs no extra CAS.     *)
StageDuplicate ==
  /\ caller.pc = "inflight"
  /\ caller.routeObs = "done"
  /\ (Fence => caller.fenceObs = "passed")
  /\ mem[caller.target].loaded
  /\ Dedupe
  /\ mem[caller.target].n > 0
  /\ caller' = [caller EXCEPT !.pc = "acked"]
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* Step two: the commit CAS trusts only the RECORDED fence observation —   *)
(* an ownership move since FenceRead is invisible here, which is exactly   *)
(* the shipped residual window.  On an etag match the append applies and   *)
(* the caller may be acked (or the reply lost).  On a mismatch the node    *)
(* reloads and the stage re-runs; the ledger is re-checked against the     *)
(* RELOADED image, which is what carries ExactlyOnceDurable.               *)
StageCommit ==
  /\ caller.pc = "inflight"
  /\ caller.routeObs = "done"
  /\ caller.staged = FALSE   \* at most ONE applied commit per attempt: a lost
                              \* reply re-enters via CallerTimeout -> CallerSend
                              \* -> FenceRead, the real protocol loop
  /\ (Fence => caller.fenceObs = "passed")
  /\ mem[caller.target].loaded
  /\ (Dedupe => mem[caller.target].n = 0)
  \* SCOPE (round-10, honest claim): this spec's birth/admission variables
  \* (birthMarker, birthStores, extLateInput) form a SEPARATELY-verified
  \* subsystem of ghost actions documenting the birth-marker and
  \* read-only-admission contracts.  The main commit below is NOT coupled
  \* to them: the correspondence between the modeled birth actions and the
  \* real creators is established by the code-side creation-point audit
  \* (plan clause 2b), the per-ingress E2Es, and their mutation checks —
  \* not by this model.  A round-9 attempt to tie the commit in here was
  \* an enabling condition no configuration depended on (deleting it
  \* changed no verdict), i.e. false assurance; it was removed rather
  \* than dressed up.
  /\ IF CanPutIfMatch(session, mem[caller.target].etag)
     THEN /\ session' = Applied(session, [n |-> session.val.n + 1, sourceFrontier |-> 1])
          /\ mem' = [mem EXCEPT ![caller.target] =
               [etag |-> ETag(session) + 1, n |-> session.val.n + 1, loaded |-> TRUE]]
          /\ staleCommits' =
               IF headOwner # caller.target THEN staleCommits + 1 ELSE staleCommits
          /\ commitRuntime' = caller.req
          /\ UNCHANGED executedOn
          /\ \/ caller' = [caller EXCEPT !.pc = "acked", !.staged = TRUE]
             \/ caller' = [caller EXCEPT !.staged = TRUE]  \* reply lost
     ELSE /\ mem' = [mem EXCEPT ![caller.target] = NotLoaded]
          /\ UNCHANGED <<session, caller, commitRuntime, executedOn,
                         staleCommits, laterStore, birthStores,
                 extBindingCurrent, extLateInput>>
  /\ UNCHANGED <<headOwner, placement, runtime, executedOn, moves,
                 laterStore, birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* A ghost second writer converging the SAME id at the owner: same ledger, *)
(* same CAS. Historical since A2 §3.4 (no staged writer or absorb exists); *)
(* kept as a deliberate over-approximation — see the header note.          *)
StagedWriter ==
  /\ Staged
  /\ mem[headOwner].loaded
  /\ (Dedupe => mem[headOwner].n = 0)
  /\ IF CanPutIfMatch(session, mem[headOwner].etag)
     THEN /\ session' = Applied(session, [n |-> session.val.n + 1, sourceFrontier |-> 1])
          /\ mem' = [mem EXCEPT ![headOwner] =
               [etag |-> ETag(session) + 1, n |-> session.val.n + 1, loaded |-> TRUE]]
     ELSE /\ mem' = [mem EXCEPT ![headOwner] = NotLoaded]
          /\ UNCHANGED session
  /\ UNCHANGED <<headOwner, placement, runtime, caller, commitRuntime, moves,
                 executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The agent's runtime kind flips internal -> external (an admin runtime  *)
(* rebind), one-way: the #843 owner-reproduced race dimension.  A caller   *)
(* classified BEFORE the flip carries req = "int" into the stage.          *)
FlipRuntime ==
  /\ runtime = "int"
  /\ runtime' = "ext"
  /\ UNCHANGED <<session, mem, headOwner, placement, caller, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The stage's ROUTING READ is where the runtime fence lives — and, like   *)
(* the owner fence, it is genuinely TWO steps: this read records its       *)
(* observation (routeObs) and the commit trusts only the record.  An       *)
(* internal-classified (require_runtime: :internal) entry that reads       *)
(* "ext" here REFUSES (:runtime_changed).  Shipped behavior (Reclassify):  *)
(* the facade re-classifies ONCE with the fresh record inside the same     *)
(* deadline and re-enters untagged — fresh hop budget, fence and route     *)
(* observations, same caller try; a second refusal surfaces to the         *)
(* caller's own retry budget.  Reclassify = FALSE models the retired       *)
(* staged-inbox detour that acked with NO session commit                   *)
(* (RpcDeliver_NoReclassify.cfg, AckImpliesDurable violation).             *)
StageRouteRead ==
  /\ caller.pc = "inflight"
  /\ (Fence => caller.fenceObs = "passed")
  /\ caller.routeObs = "none"
  /\ IF caller.req = "int" /\ runtime = "ext"
     THEN IF Reclassify /\ ~caller.recl
          THEN caller' = [caller EXCEPT !.req = "ext", !.recl = TRUE,
                                        !.hops = 0, !.fenceObs = "none",
                                        !.routeObs = "none"]
          ELSE IF Reclassify
               THEN IF caller.tries < RetryLimit
                    THEN caller' = [caller EXCEPT !.pc = "idle",
                                                  !.tries = @ + 1]
                    ELSE caller' = [caller EXCEPT !.pc = "gaveup"]
               ELSE caller' = [caller EXCEPT !.pc = "acked"]
     ELSE caller' = [caller EXCEPT !.routeObs = "done"]
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, commitRuntime,
                 moves, executedOn,
                 staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* Post-commit wake and round execution.  The execution authority is the   *)
(* SESSION, whose runtime was fixed at its birth (owner ruling 2026-08-15, *)
(* plan clause 2b): the wake target captured at commit runs on             *)
(* commitRuntime, never re-reading the mutable agent record.  This is the  *)
(* modeled post-commit transition the round-4 review asked for.            *)
WakeExecute ==
  /\ caller.pc = "acked"
  /\ commitRuntime # "none"
  /\ executedOn = "none"
  /\ executedOn' = commitRuntime
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, moves, staleCommits, laterStore,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* A LATER, ordinary delivery to the SAME session id, well after its birth *)
(* commit — the #873 round-5 dimension.  SessionAuthority = TRUE is the    *)
(* shipped session-grain routing: the stage resolves the session's birth   *)
(* store FIRST (existence probe, SessionDelivery.session_birth_runtime/2), *)
(* so the later copy continues the birth session no matter what the agent  *)
(* record says by now.  FALSE is the retired agent-record routing, which   *)
(* after FlipRuntime fabricates a second same-id session in the other      *)
(* store (RpcDeliver_NoSessionAuthority.cfg, the round-5 repro: source A   *)
(* internal, source B external, one session id).                           *)
DeliverLater ==
  /\ commitRuntime # "none"
  /\ laterStore = "none"
  /\ laterStore' = IF SessionAuthority THEN commitRuntime ELSE runtime
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits,
                 birthMarker, birthStores,
                 extBindingCurrent, extLateInput>>

(* The BIRTH-OVERLAP dimension (#873 round 6): concurrent FIRST deliveries *)
(* to the same new session id.  The existence probe and the store create   *)
(* are two objects, so read-side routing alone cannot serialize the birth  *)
(* — the round-6 repro had two writers probe "exists nowhere", read the    *)
(* agent record on opposite sides of FlipRuntime, and create the id in     *)
(* both stores.  `reqSide` ranges over BOTH values adversarially, over-    *)
(* approximating any interleaving of admission reads and flips (safety     *)
(* under the over-approximation is stronger than under the real            *)
(* protocol's reachable reads).                                            *)
(*                                                                         *)
(* Shipped behavior (BirthAuthority): a writer first CLAIMS the per-       *)
(* session create-once marker (single-object CAS — BirthClaim), and every  *)
(* store create follows the RECORDED side (BirthCreate) — the winner's     *)
(* claim decides, losers place on the recorded side, and the crash window  *)
(* (marker claimed, create never done) stays safe because creates only    *)
(* ever follow the marker.  BirthAuthority = FALSE retires the marker:     *)
(* each writer creates on its own admission read                           *)
(* (RpcDeliver_NoBirthAuthority.cfg, AtMostOneBirthStore's expected        *)
(* violation).                                                             *)
(* Under ProbeAuthority a claim is only reachable after BOTH stores        *)
(* CONFIRMED absence (birthStores = {} is the truthful probe answer);      *)
(* ProbeAuthority = FALSE retires that: a probe ERROR read as absence      *)
(* lets a writer claim a marker for an id whose legacy session already     *)
(* exists (RpcDeliver_NoProbeAuthority.cfg).                               *)
BirthClaim(reqSide) ==
  /\ BirthAuthority
  /\ birthMarker = "none"
  /\ (ProbeAuthority => birthStores = {})
  /\ birthMarker' = reqSide
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthStores,
                 extBindingCurrent, extLateInput>>

BirthCreate(reqSide) ==
  /\ IF BirthAuthority
     THEN /\ birthMarker # "none"
          /\ birthStores' = birthStores \cup {birthMarker}
     ELSE birthStores' = birthStores \cup {reqSide}
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker,
                 extBindingCurrent, extLateInput>>

(* An UNROUTED creator (#873 round 8): a code path that reaches a store    *)
(* create without SessionDelivery's routing — the direct external-runtime  *)
(* facade, fork/seed.  With StoreGuard the store's own create primitive    *)
(* claims/follows the marker, so such a creator is just BirthClaim +       *)
(* BirthCreate like everyone else and this action is disabled.  Without    *)
(* it, the creator writes on its own side ignoring the marker — the two    *)
(* round-8 bypass repros (RpcDeliver_NoStoreGuard.cfg, expected violation  *)
(* of AtMostOneBirthStore).                                                *)
BypassCreate(reqSide) ==
  /\ ~StoreGuard
  /\ birthStores' = birthStores \cup {reqSide}
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker,
                 extBindingCurrent, extLateInput>>

(* The round-9 P1-2 dimension, as a DOCUMENTATION GHOST (round-10 scope): *)
(* an externally-born session whose binding has LEFT (rebind/flip away).  *)
(* A NEW input id arriving afterwards must be refused (comma-31 read_only;  *)
(* committed ids keep acking as duplicates through the ledger).  These    *)
(* two actions document the admission contract and its retired escape     *)
(* (RpcDeliver_NoStrictWritable.cfg, expected violation); they do NOT     *)
(* constrain the main commit above — enforcement on the real path is      *)
(* held by ensure_new_input_admissible and its E2Es (minted-capability    *)
(* flip; ext->ext rollout pinning; wait settlement), each mutation-       *)
(* checked in code.                                                       *)
Rebind ==
  /\ extBindingCurrent
  /\ extBindingCurrent' = FALSE
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker, birthStores, extLateInput>>

LateExternalInput ==
  /\ "ext" \in birthStores
  /\ ~extBindingCurrent
  /\ extLateInput = "none"
  /\ extLateInput' = IF StrictWritable THEN "refused" ELSE "admitted"
  /\ UNCHANGED <<session, mem, headOwner, placement, runtime, caller,
                 commitRuntime, executedOn, moves, staleCommits, laterStore,
                 birthMarker, birthStores, extBindingCurrent>>

Next ==
  \/ MoveOwner
  \/ SyncPlacement
  \/ FlipRuntime
  \/ CallerSend
  \/ CallerTimeout
  \/ FenceRead
  \/ StageRouteRead
  \/ StageDuplicate
  \/ StageCommit
  \/ StagedWriter
  \/ WakeExecute
  \/ DeliverLater
  \/ Rebind
  \/ LateExternalInput
  \/ \E side \in {"int", "ext"}:
       BirthClaim(side) \/ BirthCreate(side) \/ BypassCreate(side)
  \/ \E nd \in Nodes: NodeLoad(nd)

Spec == Init /\ [][Next]_vars

(* The id lands durably at most once — under retries, loss, moves, hops,   *)
(* mixed writers.  The load-bearing mechanism is dedupe-after-reload, not  *)
(* the fence.                                                              *)
ExactlyOnceDurable == session.val.n <= 1

(* Only target input is modeled. Deterministic non-target scans are omitted. *)
SourceFrontierImpliesDurable == session.val.sourceFrontier = 1 => session.val.n >= 1

(* An ack is only ever sent after an applied append or a ledger hit.       *)
AckImpliesDurable == caller.pc = "acked" => session.val.n = 1

(* Expected-violation property: see the module comment.                    *)
NoStaleCommit == staleCommits = 0

(* Expected-violation property (RpcDeliver_LateFlipResidual.cfg): a flip   *)
(* AFTER the routing read but BEFORE the commit lands the copy in a        *)
(* session of the runtime the AGENT record just left.  Under the runtime-  *)
(* authority ruling (owner 2026-08-15, plan clause 2b) this is the         *)
(* admission-race BOUNDARY, not a defect: the agent-record comparison is   *)
(* deliberately NOT an invariant, while the session-grain property         *)
(* ExecutionOnSessionRuntime below holds structurally.  A true cross-      *)
(* object fence is the construction the north star forbids.                *)
AckMatchesAgentRuntime ==
  caller.pc = "acked" => (commitRuntime \in {"none", runtime})

(* The execution authority is the session: a woken round runs on the       *)
(* runtime the committed session was born with — never on a re-read of     *)
(* the mutable agent record.  This is what makes the admission race safe:  *)
(* work never executes on a runtime its session does not truthfully carry. *)
ExecutionOnSessionRuntime ==
  executedOn \in {"none", commitRuntime}

(* One session id, one store: a later delivery to an already-born session  *)
(* lands in that session's birth store.  Holds structurally under          *)
(* SessionAuthority — routing consults the session's own existence, never  *)
(* the mutable agent record.  The expected violation with SessionAuthority *)
(* = FALSE is the round-5 split.                                           *)
NoSplitSession == laterStore \in {"none", commitRuntime}

(* One session id is born in at most ONE store, under concurrent first     *)
(* deliveries and adversarial admission reads.  Holds structurally under   *)
(* BirthAuthority — every create follows the single durable marker; the    *)
(* expected violation with BirthAuthority = FALSE is the round-6           *)
(* birth-overlap repro (source A internal, source B external, one id).    *)
AtMostOneBirthStore == birthStores # {"int", "ext"}

(* After the binding leaves an externally-born session, no NEW input is    *)
(* ever admitted — the comma-31 read_only clause as an invariant.  Holds     *)
(* under StrictWritable; the expected violation without it is the round-9  *)
(* capability-escape repro.                                                *)
NoLateExternalAdmission == extLateInput # "admitted"

(* Execution-reachability witness (round-5 model finding: an UNCHANGED     *)
(* contradiction had made WakeExecute unsatisfiable, so                    *)
(* ExecutionOnSessionRuntime passed vacuously).  Under weak fairness on    *)
(* the wake, every acked session commit eventually executes — checked as a *)
(* temporal property (RpcDeliver_ExecutionWitness.cfg) so the safety       *)
(* invariant can never go vacuous again unnoticed.                         *)
FairSpec == Spec /\ WF_vars(WakeExecute)

ExecutionReachable ==
  (caller.pc = "acked" /\ commitRuntime # "none") ~> (executedOn # "none")

=============================================================================
