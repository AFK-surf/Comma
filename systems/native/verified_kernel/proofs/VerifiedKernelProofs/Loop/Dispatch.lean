import VerifiedKernelProofs.Loop.Host
import VerifiedKernelProofs.Loop.Shape
import VerifiedKernelProofs.AgentLoop.Round
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Session.WorkRetirement
import VerifiedKernelProofs.Session.WorkCanonical
import VerifiedKernelProofs.Session.WorkAllocation
import VerifiedKernelProofs.Proof.NativeProducerTactic

/-! # Property B: recorded, non-duplicated side effects

This module proves property B of issue #2070 on the host trace model of
`Loop/Host.lean`. The dispatch key is the assistant message id `aid`.

* `dispatch_at_most_once`: two dispatches never share an `aid`, unless the
  first is a speculative dispatch whose durable fence failed (`Retracted`).
  `dispatch_keys_nodup` states the key form `(aid, mode)` for runs without a
  failed speculative fence. Hypotheses: an integer `next_message_id` of at
  least 0 in the initial durable state, and H2 (`RecordsPositioned`).
* `dispatch_after_durable_intent`: a non-speculative model-turn dispatch
  follows a durable commit of the intent events of the record that the host
  built for the same `aid` and calls. No hypothesis beyond the model.
  `dispatch_after_durable_assistant` adds H2 (`RecordsCarryAssistant`): the
  committed events hold the assistant event at `aid`.
* `notice_after_durable_record`: a runtime failure notice dispatch follows a
  durable commit of the kernel-built notice assistant event at the same `aid`
  with the dispatched call. `dispatch_modes`: every non-speculative dispatch
  is a model turn or this notice, so B1 covers every dispatch.
* `speculative_dispatch`: a speculative dispatch directly follows the working
  write of its intent record. Its calls are read-only by H4
  (`SpeculativeReadOnly`).
* `round_refines`, `intent_once_per_round`, `dispatch_once_per_round`: the
  proven `AgentLoop.Round` machine, fed with the durable acknowledgements of a
  round, issues `executeTools` at the intent commit and waits in `awaitTools`
  when the host dispatches. A round has at most one intent commit and one
  model-turn dispatch.

The model encodes H1 (a commit lands on the state that the step read, and
effects after it run only after success) and H6 (a crash drops the machine,
and recovery only commits the `restart_plan` output). Property B needs no
assumption on other writers (Env): every event batch keeps the durable
`next_message_id` from decreasing.

The proofs use kernel facts that this module proves: the monotonic
`next_message_id` (`batch_nmi`), the effect of the `hwm` option of a commit
(`landed_bump`), and three facts about the machine of a step (`step_facts`,
`step_round`, `step_intent_round`). `Loop/Shape.lean` supplies the commit and
dispatch sources (`stepSources`). -/

namespace VerifiedKernel.Session.LoopProof.Dispatch
open Data WorkConservation

set_option Elab.async false
set_option maxHeartbeats 1000000
set_option linter.unusedSimpArgs false

/-! ## The next message id never decreases -/

/-- `next_message_id` is an integer of at least `n`. -/
def NmiAtLeast (s : Term) (n : Int) : Prop := ∃ m : Int, s.get (a "next_message_id") = .integer m ∧ n ≤ m

/-- A transition keeps every lower bound of `next_message_id`. -/
def NmiStep (s t : Term) : Prop := ∀ n, NmiAtLeast s n → NmiAtLeast t n

theorem nmi_refl (s : Term) : NmiStep s s := fun _ h => h

theorem nmi_trans {s t u : Term} (first : NmiStep s t) (second : NmiStep t u) : NmiStep s u :=
  fun n h => second n (first n h)

theorem nmi_of_frame {s t : Term} (same : t.get (a "next_message_id") = s.get (a "next_message_id")) :
    NmiStep s t := fun _ ⟨m, hm, le⟩ => ⟨m, same.trans hm, le⟩

theorem NmiAtLeast.mono {s : Term} {n k : Int} (h : NmiAtLeast s n) (le : k ≤ n) : NmiAtLeast s k :=
  let ⟨m, hm, hn⟩ := h
  ⟨m, hm, Int.le_trans le hn⟩

theorem write_nmi_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (kept : entries.all (fun entry => entry.1 != "next_message_id") = true) : NmiStep s t :=
  nmi_of_frame (write_field_frame h kept)

theorem write_nmi_frame_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "next_message_id") = true → NmiStep s t) :=
  step_iff write_nmi_frame

syntax "nmi_step" ident : tactic
macro_rules
  | `(tactic| nmi_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_nmi_frame_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine nmi_trans (kept rfl) ?_)
      | (head_step $h "_nmi_step"; obtain ⟨_, kept⟩ := $h; refine nmi_trans kept ?_))

syntax "nmi_walk" ident : tactic
macro_rules
  | `(tactic| nmi_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact nmi_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (nmi_step $h; exact nmi_refl _)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [field, fetch]; simp only [field, fetch_ok_iff] at $hx:ident
              obtain ⟨_, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Data.append]; simp only [append_ok_iff] at $hx:ident
              obtain ⟨_, _, $hl:ident, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
           | nmi_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | nmi_step $hx
               | ((repeat (fail_if_success nmi_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  nmi_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

/-- `nmi_rule f (state x y)` proves `f_nmi` and `f_nmi_step` by the walk. -/
syntax "nmi_rule " ident " (" ident+ ")" : command
macro_rules
  | `(nmi_rule $fn:ident ($args:ident*)) => do
    let lemma := Lean.mkIdent (fn.getId.appendAfter "_nmi")
    let step := Lean.mkIdent (fn.getId.appendAfter "_nmi_step")
    let state := args[0]!
    let binders ← args.mapM (fun arg => `(bracketedBinder| {$arg : Term}))
    let applied ← args.foldlM (fun acc arg => `(term| $acc $arg)) (← `(term| $fn))
    let first ← `(command|
      theorem $lemma $binders:bracketedBinder* {next : Term} {journal rest : List Term}
          (call : $applied journal = .ok (next, rest)) : NmiStep $state next := by
        unfold $fn at call
        nmi_walk call)
    let second ← `(command|
      theorem $step $binders:bracketedBinder* {next : Term} {journal rest : List Term} :
          $applied journal = .ok (next, rest) ↔
            Except.ok (next, rest) = $applied journal ∧ NmiStep $state next := step_iff $lemma)
    return Lean.mkNullNode #[first, second]

/-- `bumpHwm` raises `next_message_id` to at least `hwm + 1` and never lowers it. -/
theorem bumpHwm_value {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    NmiStep s t ∧ ∀ m h₀ : Int, s.get (a "next_message_id") = .integer m → hwm = .integer h₀ → 0 ≤ h₀ →
      NmiAtLeast t (h₀ + 1) := by
  unfold bumpHwm at h
  split at h
  · rename_i guard
    obtain ⟨v, _, hv, h⟩ := bind_ok h
    simp only [field, fetch_ok_iff] at hv
    obtain ⟨_, _, rfl, _⟩ := hv
    obtain ⟨w, _, hw, h⟩ := bind_ok h
    obtain ⟨x, _, hx, h⟩ := bind_ok h
    have written := write_get_key "next_message_id" h rfl
    have hint : ∃ h₀ : Int, hwm = .integer h₀ := by
      cases hwm <;> simp_all [Term.isInteger]
    obtain ⟨h₀, rfl⟩ := hint
    rw [add_integer] at hw
    simp only [Except.ok.injEq, Prod.mk.injEq] at hw
    obtain ⟨rfl, rfl⟩ := hw
    have value : ∀ m : Int, s.get (a "next_message_id") = .integer m → x = .integer (max m (h₀ + 1)) := by
      intro m hm
      rw [hm, default_integer, maximum_integer] at hx
      simp only [Except.ok.injEq, Prod.mk.injEq] at hx
      exact hx.1.symm
    refine ⟨fun n ⟨m, hm, le⟩ => ⟨max m (h₀ + 1), by rw [written, value m hm], ?_⟩, ?_⟩
    · exact Int.le_trans le (Int.le_max_left _ _)
    · intro m h₁ hm hh _
      cases hh
      exact ⟨max m (h₀ + 1), by rw [written, value m hm], Int.le_max_right _ _⟩
  · rename_i guard
    have same := pure_ok h
    subst t
    refine ⟨nmi_refl _, ?_⟩
    intro m h₀ _ hh nonneg
    subst hh
    simp [Term.isInteger, integerValue, nonneg] at guard

theorem bumpHwm_nmi {s hwm t : Term} {j r : List Term} (h : bumpHwm s hwm j = .ok (t, r)) :
    NmiStep s t := (bumpHwm_value h).1

theorem bumpHwm_nmi_step {s hwm t : Term} {j r : List Term} :
    bumpHwm s hwm j = .ok (t, r) ↔ Except.ok (t, r) = bumpHwm s hwm j ∧ NmiStep s t :=
  step_iff bumpHwm_nmi


nmi_rule appendFields (state event message)
nmi_rule appendMessage (state event message)
nmi_rule noteResult (state tool input status errorClass message content)
nmi_rule noteAsyncResult (state existing event status)
nmi_rule asyncStart (state event)
nmi_rule asyncTerminal (state event status)
nmi_rule resetFresh (state message)
nmi_rule addObligation (state raw)
nmi_rule obligationResolve (state key)
nmi_rule obligationCard (state conversation limit)
nmi_rule replyRepair (state event)
nmi_rule replyIntent (state event)
nmi_rule retireIntent (state event)
nmi_rule activationStarted (state raw)
nmi_rule activationFinished (state identity)
nmi_rule sessionAck (state event)
nmi_rule pruneResultRefs (state)
nmi_rule waitClear (state event)
nmi_rule statusTransition (state event)
nmi_rule activityTransition (state event)
nmi_rule metadataCreated (state event)
nmi_rule conversationSourceAdvance (state event)
nmi_rule metadataPrompt (state event)
nmi_rule metadataUpdate (state event)
nmi_rule stampWorkReasons (state event)
nmi_rule stampAgentId (state event)
nmi_rule stampRuntimeEpoch (state event)
nmi_rule stampRuntimeNode (state event)
nmi_rule stampActivityRevision (state event)
nmi_rule stampStorageRevision (state event)
nmi_rule stampFlushId (state event)
nmi_rule stampWorkIndexToken (state event)
nmi_rule sessionStamp (state event)
nmi_rule bumpHwmEvent (state event)
nmi_rule compactionFailure (state event)
nmi_rule compactionRecovery (state event)
nmi_rule progressStep (state event)
nmi_rule pruneCompactResults (state)
nmi_rule recomputeContext (state)

set_option backward.split false in
theorem historyCompaction_nmi {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : NmiStep s t := by
  unfold historyCompaction at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.recomputeContext"
       exact recomputeContext_nmi h)
    | (execution_head_is h "Pure.pure"
       have same := pure_ok h
       subst t
       exact nmi_refl _)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine nmi_trans (write_nmi_frame prior rfl) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneResultRefs"
            refine nmi_trans (pruneResultRefs_nmi prior) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneCompactResults"
            refine nmi_trans (pruneCompactResults_nmi prior) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem historyCompaction_nmi_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔
      Except.ok (t, r) = historyCompaction s e provider j ∧ NmiStep s t :=
  step_iff historyCompaction_nmi

set_option backward.split false in
theorem compactResult_nmi {s e t : Term} {j r : List Term} (h : compactResult s e j = .ok (t, r)) :
    NmiStep s t := by
  unfold compactResult at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.pruneCompactResults"
       exact pruneCompactResults_nmi h)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine nmi_trans (write_nmi_frame prior rfl) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem compactResult_nmi_step {s e t : Term} {j r : List Term} :
    compactResult s e j = .ok (t, r) ↔ Except.ok (t, r) = compactResult s e j ∧ NmiStep s t :=
  step_iff compactResult_nmi

nmi_rule storedResult (state event)
nmi_rule transcriptToolResult (state event)
nmi_rule transcriptAssistant (state event)
nmi_rule transcriptLog (state event)
nmi_rule runtimeAppend (state event)
nmi_rule transcriptRuntime (state event)
/-- The seed fold keeps the running message id at or above `m`. -/
def SeedNext (m : Int) (acc : List Term × Term × Term × Bool × Term) : Prop :=
  ∃ k : Int, acc.2.1 = .integer k ∧ m ≤ k

theorem transcriptSeed_nmi {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    NmiStep s t := by
  unfold transcriptSeed at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  try dsimp only at h
  obtain ⟨folded, _, hfold, h⟩ := bind_ok h
  obtain ⟨items, hitems, -⟩ := enumFold_ok hfold
  have foldInv := foldlM_inv
    (fun acc => ∀ m : Int, s.get (a "next_message_id") = .integer m → SeedNext m acc)
    ?preserve (fun m hm => ⟨m, by simp only [hm, default_integer], Int.le_refl m⟩) hitems
  case preserve =>
    intro acc item s' r' acc' hP hstep m hm
    obtain ⟨ms, nx, sn, an, sq⟩ := acc
    obtain ⟨k, hk, hmk⟩ := hP m hm
    simp only at hk
    subst hk
    dsimp only at hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    split at hstep
    · simp only [pure_ok_iff, Prod.mk.injEq] at hstep
      obtain ⟨rfl, -⟩ := hstep
      exact ⟨k, rfl, hmk⟩
    · obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
      obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
      try dsimp only at hstep
      obtain ⟨_, _, hadd, hstep⟩ := bind_ok hstep
      rw [add_integer] at hadd
      simp only [Except.ok.injEq, Prod.mk.injEq] at hadd
      obtain ⟨rfl, rfl⟩ := hadd
      obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
      simp only [pure_ok_iff, Prod.mk.injEq] at hstep
      obtain ⟨rfl, -⟩ := hstep
      exact ⟨k + 1, rfl, Int.le_trans hmk (Int.le_add_one (Int.le_refl k))⟩
  clear hfold hitems
  obtain ⟨appended, nextId, dedupe, any, lastSeq⟩ := folded
  try dsimp only at h foldInv
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, hf, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, hmax, h⟩ := bind_ok h
  all_goals obtain ⟨seeded, _, hw, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, _, hfinal⟩ := bind_ok h
  all_goals
    simp only [field, fetch_ok_iff] at hf
    obtain ⟨_, _, rfl, _⟩ := hf
    rintro n ⟨m, hm, hnm⟩
    obtain ⟨k, hk, hmk⟩ := foldInv m hm
    try simp only at hk
    subst hk
    rw [hm, default_integer, maximum_integer] at hmax
    simp only [Except.ok.injEq, Prod.mk.injEq] at hmax
    obtain ⟨rfl, -⟩ := hmax
    have written := write_get_key "next_message_id" hw rfl
    have kept := write_frame_key "next_message_id" hfinal rfl
    exact ⟨max k m, by rw [kept, written], Int.le_trans hnm (Int.le_max_right _ _)⟩

theorem transcriptSeed_nmi_step {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ NmiStep s t :=
  step_iff transcriptSeed_nmi

nmi_rule transcriptDelivery (state event)
nmi_rule queueAppend (state event)
nmi_rule queueAck (state event)
nmi_rule queueConsume (state event)
nmi_rule sessionEvent (state event)

theorem mergePredicate_nmi {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) : NmiStep s t := by
  unfold mergePredicate at h
  repeat' first
    | exact write_nmi_frame h rfl
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem mergePredicate_nmi_step {s kind through replacement extra t : Term} {j r : List Term} :
    mergePredicate s kind through replacement extra j = .ok (t, r) ↔
      Except.ok (t, r) = mergePredicate s kind through replacement extra j ∧ NmiStep s t :=
  step_iff mergePredicate_nmi

theorem microcompactIds_nmi {s replacement e t : Term} {ids j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) : NmiStep s t := by
  unfold microcompactIds at h
  nmi_walk h

theorem microcompactIds_nmi_step {s replacement e t : Term} {ids j r : List Term} :
    microcompactIds s ids replacement e j = .ok (t, r) ↔
      Except.ok (t, r) = microcompactIds s ids replacement e j ∧ NmiStep s t :=
  step_iff microcompactIds_nmi

nmi_rule microcompact (state event)
nmi_rule capabilitySync (state event)
nmi_rule archiveAdvance (state event)

theorem afterEvent_nmi {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : NmiStep next t := by
  unfold afterEvent at h
  nmi_walk h

/-- Every dispatched event keeps every lower bound of `next_message_id`. -/
theorem inner_nmi {state event next : Term} {journal rest : List Term}
    (h : inner state event journal = .ok (next, rest)) : NmiStep state next := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  nmi_walk h

theorem prepareTrusted_nmi {state raw next : Term} {normalized : Option Term} {journal rest : List Term}
    (h : prepareTrusted state raw journal = .ok ((next, normalized), rest)) : NmiStep state next := by
  cases normalized with
  | none => rw [prepareTrusted_none h]; exact nmi_refl _
  | some event =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify h
    exact inner_nmi reduced

theorem activity_frame_nmi {s t : Term} (frame : ActivityFrame s t) : NmiStep s t :=
  nmi_of_frame (frame "next_message_id" (by decide) (by decide))

/-- One resident event keeps every lower bound of `next_message_id`. -/
theorem resident_nmi {s e t : Term} {observations : List Term}
    (trace : ResidentTrace (runTrusted s e observations) (.tuple [a "done", t])) : NmiStep s t := by
  intro n start
  exact resident_execution_preserves (P := fun state => NmiAtLeast state n) start
    (fun _ _ _ _ prepared => prepareTrusted_nmi prepared n start)
    (fun _ _ valid frame => activity_frame_nmi frame n valid) trace

/-- A landed batch keeps every lower bound of `next_message_id`. -/
theorem batch_nmi {s t : Term} {events : List Term} (batch : ResidentBatch s events t) : NmiStep s t := by
  induction batch with
  | nil => exact nmi_refl _
  | cons head _ ih => exact nmi_trans (resident_nmi head) ih

theorem batch_append {s t : Term} {xs ys : List Term} (batch : ResidentBatch s (xs ++ ys) t) :
    ∃ u, ResidentBatch s xs u ∧ ResidentBatch u ys t := by
  induction xs generalizing s with
  | nil => exact ⟨s, .nil s, batch⟩
  | cons x rest ih =>
    cases batch with
    | cons head tail =>
      obtain ⟨u, left, right⟩ := ih tail
      exact ⟨u, .cons head left, right⟩

/-! ## The `bump_hwm` event of a commit -/

/-- The `bump_hwm` event that `hwmEvents` builds. -/
def bumpEvent (hwm : Term) : Term := .map [(b "type", b "bump_hwm"), (b "hwm", hwm)]

theorem hwmEvents_integer {n : Int} (nonneg : 0 ≤ n) :
    PendingRevision.hwmEvents (.integer n) = [bumpEvent (.integer n)] := by
  simp [PendingRevision.hwmEvents, bumpEvent, Term.isInteger, integerValue, nonneg]

theorem bumpEvent_keys (hwm : Term) : BinaryKeys (bumpEvent hwm) := by
  simp [BinaryKeys, bumpEvent, Term.isBinary, b, Term.text]

theorem inner_bump {s next : Term} {n : Int} {j r : List Term} (nonneg : 0 ≤ n) (start : NmiAtLeast s 0)
    (h : inner s (bumpEvent (.integer n)) j = .ok (next, r)) : NmiAtLeast next (n + 1) := by
  unfold inner at h
  simp only [bumpEvent, Term.get, List.find?, binary_key_beq] at h
  simp (config := { decide := true }) only [Option.map, Option.getD] at h
  unfold bumpHwmEvent at h
  obtain ⟨hwm, _, read, h⟩ := bind_ok h
  simp only [Data.event, access] at read
  simp (config := { decide := true }) [Term.isMap, Term.has, Term.get, List.any,
    BEq.beq, pure_ok_iff] at read
  obtain ⟨rfl, -⟩ := read
  obtain ⟨m, hm, -⟩ := start
  exact (bumpHwm_value h).2 m n hm rfl nonneg

/-- A prepared `bump_hwm` event is never skipped, and it raises `next_message_id` above `n`. -/
theorem prepare_bump {s next : Term} {normalized : Option Term} {n : Int} {j r : List Term}
    (nonneg : 0 ≤ n) (start : NmiAtLeast s 0)
    (h : prepareTrusted s (bumpEvent (.integer n)) j = .ok ((next, normalized), r)) :
    normalized.isSome ∧ NmiAtLeast next (n + 1) := by
  have skip : ((bumpEvent (.integer n)).get (b "session_id")).isBinary = false := by
    simp (config := { decide := true }) only [bumpEvent, Term.get, List.find?, binary_key_beq]
    rfl
  unfold prepareTrusted at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    pure_ok_iff, Prod.mk.injEq, reduceCtorEq] at h
  obtain ⟨-, -, event, rest, read, h⟩ := h
  have same := shallowStringify_binary_keys (bumpEvent_keys _) read
  subst event
  rw [skip] at h
  simp only [Bool.false_and, Bool.false_eq_true, false_and, false_or, not_false_eq_true, true_and] at h
  obtain ⟨reduced, _, inner_h, ⟨rfl, rfl⟩, rfl⟩ := h
  exact ⟨rfl, inner_bump nonneg start inner_h⟩

/-- The resident execution states of one `bump_hwm` event. -/
def BumpToken (u : Term) (n : Int) : Term → Prop
  | .tuple [.atom "reduce", state, event, .list _] => state = u ∧ event = bumpEvent (.integer n)
  | .tuple [.atom "activity", resident, _, _, _, .list _] => NmiAtLeast resident (n + 1)
  | _ => False

def BumpResult (u : Term) (n : Int) : Term → Prop
  | .tuple [.atom "done", state] => NmiAtLeast state (n + 1)
  | .tuple [.atom "observe", _, token] => BumpToken u n token
  | _ => True

theorem runActivityTrusted_bump {u state next event : Term} {n : Int} {observations : List Term}
    (valid : NmiAtLeast next (n + 1)) :
    BumpResult u n (runActivityTrusted state next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent state next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact activity_frame_nmi (afterEvent_activity_frame result) _ valid
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_bump {u : Term} {n : Int} {observations : List Term} (nonneg : 0 ≤ n)
    (start : NmiAtLeast u 0) : BumpResult u n (runTrusted u (bumpEvent (.integer n)) observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted u (bumpEvent (.integer n)) observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      obtain ⟨some, raised⟩ := prepare_bump nonneg start result
      cases normalized with
      | none => cases some
      | some event => dsimp only; exact runActivityTrusted_bump raised
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_bump {u token observation : Term} {n : Int} (nonneg : 0 ≤ n)
    (start : NmiAtLeast u 0) (valid : BumpToken u n token) :
    BumpResult u n (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · rename_i state event observations
      obtain ⟨rfl, rfl⟩ := valid
      exact runTrusted_bump nonneg start
    · rename_i resident state next event observations
      change NmiAtLeast resident (n + 1) at valid
      dsimp only
      cases result : afterEvent state next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change NmiAtLeast (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status"))) (n + 1)
          obtain ⟨m, hm, le⟩ := valid
          refine ⟨m, ?_, le⟩
          split
          · rw [get_put_other _ _ (by decide), get_put_other _ _ (by decide), hm]
          · rw [get_put_other _ _ (by decide), hm]
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · exact absurd valid (by simp only [BumpToken]; exact id)

theorem trace_bump {u initial final : Term} {n : Int} (nonneg : 0 ≤ n) (start : NmiAtLeast u 0)
    (trace : ResidentTrace initial final) (valid : BumpResult u n initial) : BumpResult u n final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_bump nonneg start valid)

/-- A commit with the integer option `hwm = n ≥ 0` leaves `next_message_id` above `n`. -/
theorem landed_bump {s t : Term} {events : List Term} {n : Int}
    (batch : ResidentBatch s (events ++ PendingRevision.hwmEvents (.integer n)) t)
    (nonneg : 0 ≤ n) (start : NmiAtLeast s 0) : NmiAtLeast t (n + 1) := by
  rw [hwmEvents_integer nonneg] at batch
  obtain ⟨u, first, last⟩ := batch_append batch
  have atU : NmiAtLeast u 0 := batch_nmi first 0 start
  cases last with
  | cons head tail =>
    cases tail with
    | nil => exact trace_bump nonneg atU head (runTrusted_bump nonneg atU)


/-! ## Machine facts of one kernel step

The walks below unfold each private helper of `Loop.lean` and check the output
machine. They copy the method of `Loop/Shape.lean`. -/

theorem put_map (v key x : Term) : (v.put key x).isMap = true := by
  cases v <;> rfl

theorem get_put_text (v x : Term) (key : String) : (v.put (b key) x).get (b key) = x := by
  cases v <;> simp [Term.put, Term.get, binary_key_beq]

open Lean Elab Tactic in
/-- `dunfold_at "Full.Private.Name" h` unfolds a private runtime helper in `h`. -/
elab "dunfold_at " requested:str h:ident : tactic => do
  let candidates := (← getEnv).constants.toList.filter fun (name, _) =>
    (privateToUserName name).toString == requested.getString
  let [(name, _)] := candidates | throwError "expected one native declaration for {requested}"
  let id := mkIdent name
  evalTactic (← `(tactic| unfold $id:ident at $h:ident))

/-- `loop_private% name`: the runtime helper `VerifiedKernel.Session.Loop.name`, private or not. -/
syntax "loop_private% " ident : term
macro_rules
  | `(loop_private% $n) => `(native_decl% $(Lean.quote ("VerifiedKernel.Session.Loop." ++ n.getId.toString)))

/-- `dunfold name` unfolds the runtime helper `Loop.name` in `h`. -/
syntax "dunfold " ident : tactic
macro_rules
  | `(tactic| dunfold $n) => do
    let h := Lean.mkIdent `h
    `(tactic| dunfold_at $(Lean.quote ("VerifiedKernel.Session.Loop." ++ n.getId.toString)) $h)

/-- Split the kernel execution `h` into its branches. Each bound action stays as a hypothesis. -/
syntax "dsplit" : tactic
macro_rules
  | `(tactic| dsplit) => do
    let h := Lean.mkIdent `h
    `(tactic|
    (repeat' first
      | exact (fail_ok $h).elim
      | (execution_head_is $h "Pure.pure"
         have returned := pure_ok $h
         clear $h
         subst returned)
      | (execution_head_is $h "Bind.bind"
         have bound := bind_ok $h
         clear $h
         rcases bound with ⟨_, _, _, $h:ident⟩)
      | dsimp only at $h:ident
      | split at $h:ident))

/-- The machine facts of one step output that property B needs. A machine in
phase `notice_cleanup` holds the aid of the notice commit of the same step, or
it keeps the aid of the step machine. Such a machine never ends a step with
`run_tools`. A tool record request leaves the machine in phase `intent` with the
requested calls. -/
def MachineFacts (state machine : Term) (out : Term) : Prop :=
  ∀ machine' effects, out = .tuple [machine', list effects] →
    (phaseIs machine' "notice_cleanup" →
      ((∃ events aid sid call, commitEffect events (hwmOpts aid) nil ∈ effects ∧
          FieldIs state "next_message_id" aid ∧ mkey machine' "notice_aid" = aid ∧
          noticeAssistant sid aid call ∈ events ∧ mkey machine' "notice" = call) ∨
        (phaseIs machine "notice_cleanup" ∧ mkey machine' "notice_aid" = mkey machine "notice_aid" ∧
          mkey machine' "notice" = mkey machine "notice")) ∧
      ∀ calls flags, effects.getLast? ≠ some (runToolsEffect calls flags)) ∧
    (∀ spec, effects.getLast? = some (.tuple [a "build_record", spec]) → phaseIs machine' "intent" →
      mkey spec "mode" = b "tools" ∧ mkey spec "calls" = mkey machine' "calls")

theorem result_eq (m : Term) (effects : List Term) :
    (loop_private% result) m effects = .tuple [m, list effects] := rfl
theorem phase_eq (m : Term) (name : String) : (loop_private% phase) m name = m.put (b "phase") (b name) := rfl
theorem key_eq (m : Term) (k : String) : (loop_private% key) m k = mkey m k := rfl
theorem stop_eq (o : Term) : (loop_private% stop) o = .tuple [a "stop", o] := rfl
theorem notify_eq (kind : String) (data : Term) : (loop_private% notify) kind data = .tuple [a "notify", a kind, data] := rfl
theorem cont_eq : (loop_private% cont) = a "continue" := rfl
theorem materialize_eq (mode : String) : (loop_private% materialize) mode = .tuple [a "materialize", a mode] := rfl
theorem fetch_eq (name : Term) : (loop_private% fetch) name = .tuple [a "fact", name] := rfl
theorem setTimer_eq (kind : String) (data : Term) :
    (loop_private% setTimer) kind data = .tuple [a "set_timer", a kind, data] := rfl
theorem commit_eq (events : List Term) (hwm mode : Term) :
    (loop_private% commit) events hwm mode = commitEffect events (hwmOpts hwm) mode := rfl

theorem recordSpec_eq (m : Term) (mode : String) (extra : List (Term × Term)) :
    (loop_private% recordSpec) m mode extra = .map ([(b "mode", b mode), (b "content", mkey m "content"),
      (b "calls", mkey m "calls"), (b "provider_meta", mkey m "provider_meta"),
      (b "trace_meta", mkey m "trace_meta"), (b "replaced_calls", mkey m "replaced_calls"),
      (b "vphase", mkey (mkey m "round") "vphase")] ++ extra) := rfl

theorem mkey_map_head (k : String) (v : Term) (rest : List (Term × Term)) :
    mkey (.map ((b k, v) :: rest)) k = v := by
  simp [mkey, Term.isMap, Term.get, List.find?, binary_key_beq]

theorem mkey_map_skip {k l : String} (v : Term) (rest : List (Term × Term)) (h : l ≠ k) :
    mkey (.map ((b l, v) :: rest)) k = mkey (.map rest) k := by
  have ne : (b l == b k) = false := by rw [binary_key_beq]; simpa using h
  simp [mkey, Term.isMap, Term.get, List.find?, ne]

theorem mkey_map_nil (k : String) : mkey (.map []) k = nil := rfl

theorem nil_eq_text (x : String) : (nil = b x) = False := by
  simp [nil, b, Term.text]

theorem text_inj {x y : String} : (b x = b y) ↔ x = y := by
  constructor
  · intro h
    simp only [b, Term.text, Term.binary.injEq] at h
    exact String.toByteArray_inj.mp h
  · rintro rfl; rfl

theorem mkey_put_self (v x : Term) (k : String) : mkey (v.put (b k) x) k = x := by
  simp [mkey, put_map, get_put_text]

theorem mkey_put_skip (v x : Term) {k l : String} (h : l ≠ k) : mkey (v.put (b l) x) k = mkey v k := by
  have hget := get_put_binary_other v x h
  unfold mkey
  rw [put_map, if_pos rfl, hget]
  cases v <;> rfl

syntax "facts_one" : tactic
macro_rules
  | `(tactic| facts_one) => `(tactic| (
    simp only [MachineFacts, result_eq, phase_eq, key_eq, stop_eq, notify_eq, cont_eq, commit_eq,
      materialize_eq, fetch_eq, setTimer_eq]
    intro m' effs same
    simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
    obtain ⟨same₁, same₂⟩ := same
    subst same₁ same₂
    refine ⟨fun hp => ?_, fun spec mem mode => ?_⟩
    · first
      | (exfalso
         simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, text_inj] at hp
         done)
      | (refine ⟨Or.inr ⟨?_, ?_, ?_⟩, ?_⟩
         · first
             | exact hp
             | (simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip] at hp; exact hp)
         · first
             | rfl
             | simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip]
         · first
             | rfl
             | simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip]
         · intro calls flags mem
           simp [runToolsEffect, commitEffect, List.getLast?_cons] at mem)
    · exfalso
      first
        | (simp [commitEffect, List.getLast?_cons] at mem; done)
        | (simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, text_inj] at mode)))

syntax "facts_close" : tactic
macro_rules
  | `(tactic| facts_close) => `(tactic| ((repeat' split) <;> facts_one))

theorem guardOutcome_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% guardOutcome) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold guardOutcome
  dsplit
  all_goals facts_close

theorem park_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% park) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold park
  dsplit
  all_goals facts_close

theorem guardNotice_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% guardNotice) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold guardNotice
  dunfold_at "VerifiedKernel.Session.Loop.finalStop" h
  dsplit
  all_goals first
    | facts_close
    | (simp only [MachineFacts, result_eq, phase_eq, key_eq, stop_eq, notify_eq, cont_eq, commit_eq]
       intro m' effs same
       simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
       obtain ⟨same₁, same₂⟩ := same
       subst same₁ same₂
       refine ⟨fun _ => ⟨Or.inl ⟨_, _, _, _, List.mem_cons_self, ⟨_, _, ‹field state "next_message_id" _ = _›⟩,
         ?_, List.mem_cons_self, ?_⟩, ?_⟩, ?_⟩
       · simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip]
       · simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip]
       · intro calls flags mem
         simp [runToolsEffect, commitEffect] at mem
       · intro spec mem
         simp [commitEffect] at mem)

theorem noticeCleanup_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% noticeCleanup) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold noticeCleanup
  dsplit
  all_goals facts_close

theorem finalize_facts {ask : Loop.Ask} {state machine terminal out : Term} {j j' : List Term}
    (h : (loop_private% finalize) ask state machine terminal j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold finalize
  dsplit
  all_goals (try simp only [MachineFacts, result_eq, phase_eq, key_eq]
             intro m' effs same
             simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
             obtain ⟨same₁, same₂⟩ := same
             subst same₁ same₂
             refine ⟨fun hp => ?_, fun spec mem mode => ?_⟩
             · exfalso
               simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, text_inj] at hp
             · exfalso
               simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip,
                 text_inj] at mode)

theorem toolTurn_facts {state machine outcome out : Term} {j j' : List Term}
    (h : (loop_private% toolTurn) machine outcome j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold toolTurn
  dsplit
  simp only [MachineFacts, result_eq, phase_eq, key_eq, notify_eq]
  intro m' effs same
  simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
  obtain ⟨same₁, same₂⟩ := same
  subst same₁ same₂
  refine ⟨fun hp => ?_, fun spec mem mode => ?_⟩
  · exfalso
    simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, text_inj] at hp
  · simp only [List.getLast?_cons_cons, List.getLast?_singleton, Option.some.injEq, Term.tuple.injEq,
      List.cons.injEq, and_true, true_and] at mem
    subst mem
    simp (config := { decide := true }) only [recordSpec_eq, List.cons_append, mkey_map_head,
      mkey_map_skip, phaseIs, mkey_put_self, mkey_put_skip]
    all_goals exact ⟨trivial, trivial⟩

theorem finalRecord_facts {ask : Loop.Ask} {state machine record out : Term} {j j' : List Term}
    (h : (loop_private% finalRecord) ask state machine record j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold finalRecord
  dsplit
  all_goals first
    | facts_close
    | exact finalize_facts h

theorem modelFailure_facts {ask : Loop.Ask} {state machine info out : Term} {recover : Bool}
    {j j' : List Term}
    (h : (loop_private% modelFailure) ask state machine info recover j = .ok (out, j')) :
    MachineFacts state machine out := by
  dunfold modelFailure
  dsplit
  all_goals facts_close

theorem modelFailed_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% modelFailed) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold modelFailed
  dsplit
  all_goals facts_close

/-- `park` moves to phase `guard_notice` and ends with `continue`. -/
theorem park_out {ask : Loop.Ask} {state machine m' eff : Term} {j j' : List Term}
    (h : (loop_private% park) ask state machine j = .ok (.tuple [m', eff], j')) :
    phaseIs m' "guard_notice" ∧ ∃ effs, eff = list effs ∧ effs.getLast? = some (a "continue") := by
  dunfold park
  dsplit
  all_goals
    simp only [result_eq, phase_eq, notify_eq, cont_eq, Term.tuple.injEq, List.cons.injEq, and_true] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨by simp [phaseIs, mkey_put_self], _, rfl, by simp⟩

/-- A step output whose machine is in phase `guard_notice` and whose last effect is `continue`. -/
theorem facts_of_park {state machine m' : Term} {prefix_ effs : List Term}
    (phase : phaseIs m' "guard_notice") (last : effs.getLast? = some (a "continue")) :
    MachineFacts state machine (.tuple [m', list (prefix_ ++ effs)]) := by
  intro m'' effects same
  simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
  obtain ⟨rfl, rfl⟩ := same
  have tail : (prefix_ ++ effs).getLast? = some (a "continue") := by
    rw [List.getLast?_append, last]; rfl
  refine ⟨fun hp => ?_, fun spec mem _ => ?_⟩
  · exfalso
    rw [phaseIs, phase] at hp
    simp [text_inj] at hp
  · rw [tail] at mem
    simp at mem

theorem outputCommitted_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% outputCommitted) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold outputCommitted
  dsplit
  all_goals first
    | facts_close
    | (obtain ⟨phase, effs, rfl, last⟩ := park_out ‹(loop_private% park) _ _ _ _ = _›
       simp only [result_eq, wrap]
       exact facts_of_park phase last)

theorem intentRecord_facts {state machine record out : Term} {j j' : List Term}
    (h : (loop_private% intentRecord) state machine record j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold intentRecord
  dsplit
  all_goals first
    | facts_close
    | exact toolTurn_facts h

theorem toolsDone_facts {ask : Loop.Ask} {state machine results async out : Term} {j j' : List Term}
    (h : (loop_private% toolsDone) ask state machine results async j = .ok (out, j')) :
    MachineFacts state machine out := by
  dunfold toolsDone
  dsplit
  all_goals first
    | facts_close

theorem resultsStored_facts {ask : Loop.Ask} {state machine events hwm base stored out : Term}
    {j j' : List Term}
    (h : (loop_private% resultsStored) ask state machine events hwm base stored j = .ok (out, j')) :
    MachineFacts state machine out := by
  dunfold resultsStored
  dsplit
  all_goals first
    | facts_close

theorem continuation_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% continuation) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold continuation
  dsplit
  all_goals first
    | facts_close
    | (obtain ⟨phase, effs, rfl, last⟩ := park_out ‹(loop_private% park) _ _ _ _ = _›
       simp only [result_eq, wrap]
       exact facts_of_park phase last)

theorem wake_or_extend {wait busy now ceiling d : Term}
    (hd : AgentLoop.WaitExtension.decide wait busy now ceiling = d) :
    d = a "wake" ∨ ∃ next, d = .tuple [a "extend", next] := by
  subst hd
  unfold AgentLoop.WaitExtension.decide
  repeat' first
    | exact Or.inl rfl
    | exact Or.inr ⟨_, rfl⟩
    | split
    | dsimp only

/-- Split a `WaitExtension.decide` match in `h` into its wake and extend cases. -/
syntax "dsplit_decide" : tactic
macro_rules
  | `(tactic| dsplit_decide) => do
    let h := Lean.mkIdent `h
    let hd := Lean.mkIdent `hd
    `(tactic| (generalize $hd:ident : AgentLoop.WaitExtension.decide _ _ _ _ = d at $h:ident
               rcases wake_or_extend $hd with rfl | ⟨_, rfl⟩ <;> dsimp only [a] at $h:ident))

theorem expire_facts {state machine busy out : Term} {j j' : List Term}
    (h : (loop_private% expire) state machine busy j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold expire
  dsplit
  all_goals try facts_close
  all_goals dsplit_decide
  all_goals dsplit
  all_goals facts_close

/-- Facts about a helper that ran on a derived machine carry over to the step machine. -/
theorem facts_lift {state machine x out : Term} (facts : MachineFacts state x out)
    (same : phaseIs x "notice_cleanup" → phaseIs machine "notice_cleanup" ∧
      mkey x "notice_aid" = mkey machine "notice_aid" ∧ mkey x "notice" = mkey machine "notice") :
    MachineFacts state machine out := by
  intro m' effs eq
  obtain ⟨notice, record⟩ := facts m' effs eq
  refine ⟨fun hp => ?_, record⟩
  obtain ⟨source, last⟩ := notice hp
  refine ⟨?_, last⟩
  rcases source with fresh | ⟨px, aid, call⟩
  · exact Or.inl fresh
  · obtain ⟨pm, am, cm⟩ := same px
    exact Or.inr ⟨pm, aid.trans am, call.trans cm⟩

syntax "lift_same" : tactic
macro_rules
  | `(tactic| lift_same) => `(tactic| (
    intro hp
    first
      | (exfalso
         simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, text_inj, phase_eq,
           mkey_map_head, mkey_map_skip, mkey_map_nil, nil_eq_text] at hp
         done)
      | (refine ⟨?_, ?_, ?_⟩
         · first
             | exact hp
             | (simp (config := { decide := true }) only [phaseIs, mkey_put_self, mkey_put_skip, phase_eq] at hp
                exact hp)
         · first
             | rfl
             | simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip, phase_eq]
         · first
             | rfl
             | simp (config := { decide := true }) only [mkey_put_self, mkey_put_skip, phase_eq])))

theorem expireEntry_facts {state machine out : Term} {j j' : List Term}
    (h : (loop_private% expireEntry) state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold expireEntry
  dsplit
  all_goals first
    | facts_close
    | exact facts_lift (expire_facts h) (by lift_same)

theorem activation_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% activation) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold activation
  dsplit
  all_goals first
    | facts_close
    | exact facts_lift (expireEntry_facts h) (by lift_same)

theorem timeoutEntry_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% timeoutEntry) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold timeoutEntry
  dsplit
  all_goals first
    | facts_close
    | exact facts_lift (expireEntry_facts h) (by lift_same)

theorem parts_cases (r : Term) : ∃ k c cl pm tm, (loop_private% parts) r = .tuple [k, c, cl, pm, tm] := by
  unfold_native "VerifiedKernel.Session.Loop.parts"
  split <;> exact ⟨_, _, _, _, _, rfl⟩

theorem classify_facts {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% classify) ask state machine j = .ok (out, j')) : MachineFacts state machine out := by
  dunfold classify
  obtain ⟨_, _, _, _, _, hp⟩ := parts_cases ((loop_private% key) machine "response")
  rw [hp] at h
  dsimp only at h
  dsplit
  all_goals try (generalize hc : AgentLoop.TurnOutcome.classify _ = c at h; dsplit)
  all_goals first
    | exact facts_lift (modelFailure_facts h) (by lift_same)
    | exact facts_lift (finalize_facts h) (by lift_same)
    | exact facts_lift (toolTurn_facts h) (by lift_same)
    | exact facts_lift (modelFailure_facts ‹_›) (by lift_same)
    | exact facts_lift (finalize_facts ‹_›) (by lift_same)
    | exact facts_lift (toolTurn_facts ‹_›) (by lift_same)

/-- The machine facts of one kernel step: a machine in phase `notice_cleanup`
comes from the notice commit of `guardNotice`, or from a step that kept it and
dispatched nothing. A tool record request leaves the machine in phase `intent`
with the requested calls. -/
theorem step_facts {ask : Loop.Ask} {state machine event out : Term} {j j' : List Term}
    (h : Loop.stepWith ask state (.tuple [machine, event]) j = .ok (out, j')) :
    MachineFacts state machine out := by
  unfold Loop.stepWith at h
  dunfold_at "VerifiedKernel.Session.Loop.finalStop" h
  dsplit
  all_goals try (simp only [ite_ok_iff] at h)
  all_goals repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := h)
  all_goals try dsplit
  all_goals first
    | facts_close
    | exact facts_lift (guardNotice_facts h) (by lift_same)
    | exact facts_lift (modelFailure_facts h) (by lift_same)
    | exact facts_lift (finalRecord_facts h) (by lift_same)
    | exact facts_lift (intentRecord_facts h) (by lift_same)
    | exact facts_lift (toolsDone_facts h) (by lift_same)
    | exact facts_lift (resultsStored_facts h) (by lift_same)
    | exact facts_lift (activation_facts h) (by lift_same)
    | exact facts_lift (timeoutEntry_facts h) (by lift_same)
    | exact facts_lift (expire_facts h) (by lift_same)
    | exact facts_lift (classify_facts h) (by lift_same)
    | exact facts_lift (outputCommitted_facts h) (by lift_same)
    | exact facts_lift (modelFailed_facts h) (by lift_same)
    | exact facts_lift (noticeCleanup_facts h) (by lift_same)
    | exact facts_lift (guardOutcome_facts h) (by lift_same)
    | exact facts_lift (continuation_facts h) (by lift_same)

/-! ## Step sources

The facts of `stepWith queryAsk` that the invariants use. `stepSources`
proves them from `Loop/Shape.lean`. -/

structure StepSources : Prop where
  shape : ∀ {s m ev m' : Term} {effs : List Term}, StepOK Loop.queryAsk s m ev m' effs → StepShape effs
  dispatch : ∀ {s m ev m' calls flags : Term} {effs : List Term}, StepOK Loop.queryAsk s m ev m' effs →
    runToolsEffect calls flags ∈ effs → DispatchSource s m ev calls flags
  commit : ∀ {s m ev m' opts mode : Term} {events effs : List Term}, StepOK Loop.queryAsk s m ev m' effs →
    commitEffect events opts mode ∈ effs → CommitSource s m ev events opts mode
  intent : ∀ {s m m' record calls flags : Term} {effs : List Term},
    StepOK Loop.queryAsk s m (.tuple [a "record", record]) m' effs → phaseIs m "intent" →
    runToolsEffect calls flags ∈ effs →
    commitEffect (intentEvents record) (hwmOpts (intentHwm record)) (intentMode record) ∈ effs

/-! ## Effect lists -/

theorem commit_kind (events : List Term) (opts mode : Term) :
    effectKind (commitEffect events opts mode) = .commit := rfl

theorem runTools_blocking (calls flags : Term) : Blocking (runToolsEffect calls flags) := rfl

theorem buildRecord_blocking (spec : Term) : Blocking (.tuple [a "build_record", spec]) := rfl

/-- A step has at most one commit. -/
theorem commit_unique {effs : List Term} (shape : StepShape effs) {e₁ e₂ : List Term} {o₁ o₂ m₁ m₂ : Term}
    (first : commitEffect e₁ o₁ m₁ ∈ effs) (second : commitEffect e₂ o₂ m₂ ∈ effs) :
    e₁ = e₂ ∧ o₁ = o₂ ∧ m₁ = m₂ := by
  obtain ⟨pre, commit, mid, last, rfl, pres, commits, mids, blocking⟩ := shape
  have only : ∀ e ∈ pre ++ commit.toList ++ mid ++ [last], effectKind e = .commit → e ∈ commit.toList := by
    intro e mem kind
    simp only [List.mem_append, List.mem_singleton] at mem
    rcases mem with ((inPre | inCommit) | inMid) | isLast
    · rw [pres e inPre] at kind; cases kind
    · exact inCommit
    · rcases mids e inMid with k | k | k | k <;> rw [k] at kind <;> cases kind
    · subst isLast; rw [blocking] at kind; cases kind
  have one := only _ first (commit_kind _ _ _)
  have two := only _ second (commit_kind _ _ _)
  cases commit with
  | none => cases one
  | some c =>
    simp only [Option.toList_some, List.mem_singleton] at one two
    rw [← one] at two
    simp only [commitEffect, Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true,
      true_and] at two
    exact ⟨two.1.symm, two.2.1.symm, two.2.2.symm⟩

/-- A blocking effect of a step is its last effect. -/
theorem blocking_last {effs : List Term} (shape : StepShape effs) {e : Term} (blocking : Blocking e)
    (mem : e ∈ effs) : effs.getLast? = some e := by
  obtain ⟨pre, commit, mid, last, rfl, pres, commits, mids, isBlocking⟩ := shape
  simp only [List.mem_append, List.mem_singleton] at mem
  rw [List.getLast?_append]
  simp only [List.getLast?_singleton, Option.some_or]
  rcases mem with ((inPre | inCommit) | inMid) | isLast
  · have k := pres e inPre; unfold Blocking at blocking; rw [k] at blocking; cases blocking
  · have k := commits e inCommit; unfold Blocking at blocking; rw [k] at blocking; cases blocking
  · unfold Blocking at blocking
    rcases mids e inMid with k | k | k | k <;> rw [k] at blocking <;> cases blocking
  · rw [isLast]

theorem mem_of_commit_split {pre post : List Term} {events : List Term} {opts mode : Term} :
    commitEffect events opts mode ∈ pre ++ commitEffect events opts mode :: post := by
  simp

/-! ## Next message ids of states -/

theorem fieldIs_get {s v : Term} {name : String} (h : FieldIs s name v) : v = s.get (a name) := by
  obtain ⟨j, j', h⟩ := h
  simp only [field, fetch_ok_iff] at h
  exact h.2.2.1

theorem integer_beq {x y : Int} (h : (Term.integer x == Term.integer y) = true) : x = y := by
  simpa [BEq.beq] using h

theorem hwmOf_integer (n : Int) : hwmOf (hwmOpts (.integer n)) = .integer n := by
  simp [hwmOpts, hwmOf, BEq.beq, nil, list]

theorem landed_integer {s t : Term} {events : List Term} {n : Int}
    (batch : ResidentBatch s (landed events (hwmOpts (.integer n))) t) (nonneg : 0 ≤ n)
    (start : NmiAtLeast s 0) : NmiAtLeast t (n + 1) := by
  unfold landed at batch
  rw [hwmOf_integer] at batch
  exact landed_bump batch nonneg start

theorem landed_nmi {s t : Term} {events : List Term} {opts : Term}
    (batch : ResidentBatch s (landed events opts) t) : NmiStep s t := batch_nmi batch

/-! ## Dispatch keys in the ghost log -/

/-- Position `i` of the log dispatches calls for the assistant message `aid`. -/
def DispatchAt (log : List HostLabel) (i : Nat) (aid : Term) : Prop :=
  ∃ calls mode speculative, log[i]? = some (.dispatch aid calls mode speculative)

/-- Position `i` is a speculative dispatch whose durable fence failed. Its
intent never became durable. -/
def Retracted (log : List HostLabel) (i : Nat) : Prop :=
  (∃ aid calls mode, log[i]? = some (.dispatch aid calls mode true)) ∧ log[i + 1]? = some .failed

/-- `aid` is an integer below the next message id of `s`. -/
def AidBelow (aid s : Term) : Prop := ∃ k : Int, aid = .integer k ∧ NmiAtLeast s (k + 1)

/-- Every dispatch that is not retracted used an aid below `n`. -/
def KeptBelow (log : List HostLabel) (n : Int) : Prop :=
  ∀ i aid, DispatchAt log i aid → ¬Retracted log i → ∃ k : Int, aid = .integer k ∧ k < n

/-- `aid` is new for the log, and a landed state `s` is already past it. -/
def FreshAid (log : List HostLabel) (s aid : Term) : Prop :=
  ∃ n : Int, aid = .integer n ∧ KeptBelow log n ∧ NmiAtLeast s (n + 1)

theorem getElem?_old {log extra : List HostLabel} {i : Nat} {x : HostLabel}
    (h : log[i]? = some x) : (log ++ extra)[i]? = some x := by
  rw [List.getElem?_append_left (List.getElem?_eq_some_iff.mp h).1]
  exact h

theorem retracted_mono {log extra : List HostLabel} {i : Nat} (h : Retracted log i) :
    Retracted (log ++ extra) i := by
  obtain ⟨⟨aid, calls, mode, at_⟩, next⟩ := h
  exact ⟨⟨aid, calls, mode, getElem?_old at_⟩, getElem?_old next⟩

theorem dispatchAt_old {log extra : List HostLabel} {i : Nat} {aid : Term}
    (h : DispatchAt (log ++ extra) i aid) (small : i < log.length) : DispatchAt log i aid := by
  obtain ⟨calls, mode, spec, at_⟩ := h
  rw [List.getElem?_append_left small] at at_
  exact ⟨calls, mode, spec, at_⟩

theorem dispatchAt_mono {log extra : List HostLabel} {i : Nat} {aid : Term}
    (h : DispatchAt log i aid) : DispatchAt (log ++ extra) i aid := by
  obtain ⟨calls, mode, spec, at_⟩ := h
  exact ⟨calls, mode, spec, getElem?_old at_⟩

theorem keptBelow_mono {log extra : List HostLabel} {n : Int} (kept : KeptBelow log n)
    (noDispatch : ∀ i aid, DispatchAt extra i aid → False) : KeptBelow (log ++ extra) n := by
  intro i aid at_ notRetracted
  by_cases small : i < log.length
  · exact kept i aid (dispatchAt_old at_ small) (fun r => notRetracted (retracted_mono r))
  · obtain ⟨calls, mode, spec, at_⟩ := at_
    rw [List.getElem?_append_right (Nat.le_of_not_lt small)] at at_
    exact (noDispatch _ _ ⟨calls, mode, spec, at_⟩).elim

theorem fresh_mono {log : List HostLabel} {s t aid : Term} (fresh : FreshAid log s aid) (step : NmiStep s t) :
    FreshAid log t aid :=
  let ⟨n, eq, kept, above⟩ := fresh
  ⟨n, eq, kept, step _ above⟩

theorem fresh_log {log extra : List HostLabel} {s aid : Term} (fresh : FreshAid log s aid)
    (noDispatch : ∀ i aid, DispatchAt extra i aid → False) : FreshAid (log ++ extra) s aid :=
  let ⟨n, eq, kept, above⟩ := fresh
  ⟨n, eq, keptBelow_mono kept noDispatch, above⟩

/-- Pairwise distinct dispatch aids, except after a retracted dispatch. -/
def Distinct (log : List HostLabel) : Prop :=
  ∀ i j aid, i < j → DispatchAt log i aid → DispatchAt log j aid → Retracted log i

/-- The labels contain no dispatch. -/
def NoDispatch (labels : List HostLabel) : Prop := ∀ i aid, DispatchAt labels i aid → False

theorem noDispatch_nil : NoDispatch [] := by
  intro i aid ⟨_, _, _, h⟩
  simp at h

theorem noDispatch_cons {x : HostLabel} {rest : List HostLabel}
    (head : ∀ aid calls mode spec, x ≠ .dispatch aid calls mode spec) (tail : NoDispatch rest) :
    NoDispatch (x :: rest) := by
  intro i aid ⟨calls, mode, spec, h⟩
  cases i with
  | zero => exact head _ _ _ _ (Option.some.inj h)
  | succ i => exact tail i aid ⟨calls, mode, spec, h⟩

syntax "no_dispatch" : tactic
macro_rules
  | `(tactic| no_dispatch) => `(tactic|
    (repeat' first
      | exact noDispatch_nil
      | (refine noDispatch_cons (fun _ _ _ _ bad => ?_) ?_; cases bad)))

theorem dispatchAt_split {log pre post : List HostLabel} {x : Nat} {aid a c md : Term} {sp : Bool}
    (hpre : NoDispatch pre) (hpost : NoDispatch post)
    (h : DispatchAt (log ++ (pre ++ HostLabel.dispatch aid c md sp :: post)) x a) :
    (x < log.length ∧ DispatchAt log x a) ∨ (x = log.length + pre.length ∧ a = aid) := by
  by_cases small : x < log.length
  · exact Or.inl ⟨small, dispatchAt_old h small⟩
  · right
    obtain ⟨calls, mode, spec, h⟩ := h
    rw [List.getElem?_append_right (Nat.le_of_not_lt small)] at h
    by_cases inPre : x - log.length < pre.length
    · rw [List.getElem?_append_left inPre] at h
      exact (hpre _ _ ⟨calls, mode, spec, h⟩).elim
    · rw [List.getElem?_append_right (Nat.le_of_not_lt inPre)] at h
      cases hx : x - log.length - pre.length with
      | zero =>
        rw [hx] at h
        simp only [List.getElem?_cons_zero, Option.some.injEq, HostLabel.dispatch.injEq] at h
        exact ⟨by omega, h.1.symm⟩
      | succ k =>
        rw [hx] at h
        simp only [List.getElem?_cons_succ] at h
        exact (hpost _ _ ⟨calls, mode, spec, h⟩).elim

theorem dispatchAt_none {log extra : List HostLabel} {x : Nat} {a : Term} (none : NoDispatch extra)
    (h : DispatchAt (log ++ extra) x a) : x < log.length ∧ DispatchAt log x a := by
  by_cases small : x < log.length
  · exact ⟨small, dispatchAt_old h small⟩
  · obtain ⟨calls, mode, spec, h⟩ := h
    rw [List.getElem?_append_right (Nat.le_of_not_lt small)] at h
    exact (none _ _ ⟨calls, mode, spec, h⟩).elim

theorem distinct_none {log extra : List HostLabel} (distinct : Distinct log) (none : NoDispatch extra) :
    Distinct (log ++ extra) := by
  intro i j aid lt first second
  obtain ⟨si, fi⟩ := dispatchAt_none none first
  obtain ⟨sj, fj⟩ := dispatchAt_none none second
  exact retracted_mono (distinct i j aid lt fi fj)

theorem distinct_extend {log pre post : List HostLabel} {aid c md : Term} {sp : Bool} {n : Int}
    (distinct : Distinct log) (eq : aid = .integer n) (kept : KeptBelow log n)
    (hpre : NoDispatch pre) (hpost : NoDispatch post) :
    Distinct (log ++ (pre ++ HostLabel.dispatch aid c md sp :: post)) := by
  intro i j a lt first second
  rcases dispatchAt_split hpre hpost first with ⟨si, fi⟩ | ⟨ei, _⟩
  · rcases dispatchAt_split hpre hpost second with ⟨sj, fj⟩ | ⟨ej, ea⟩
    · exact retracted_mono (distinct i j a lt fi fj)
    · subst ea
      by_cases r : Retracted log i
      · exact retracted_mono r
      · obtain ⟨k, hk, lk⟩ := kept i _ fi r
        rw [eq] at hk
        cases hk
        exact absurd lk (Int.lt_irrefl _)
  · rcases dispatchAt_split hpre hpost second with ⟨sj, _⟩ | ⟨ej, _⟩ <;> omega

theorem keptBelow_of {log : List HostLabel} {base s : Term} {b0 : Int}
    (kept : ∀ i aid, DispatchAt log i aid → Retracted log i ∨ AidBelow aid base)
    (reach : NmiStep base s) (read : s.get (a "next_message_id") = .integer b0) : KeptBelow log b0 := by
  intro i aid at_ notRetracted
  rcases kept i aid at_ with r | ⟨k, rfl, above⟩
  · exact (notRetracted r).elim
  · obtain ⟨m, hm, le⟩ := reach _ above
    rw [read] at hm
    cases hm
    exact ⟨k, rfl, by omega⟩

theorem keptBelow_le {log : List HostLabel} {n m : Int} (kept : KeptBelow log n) (le : n ≤ m) :
    KeptBelow log m := by
  intro i aid at_ nr
  obtain ⟨k, eq, lt⟩ := kept i aid at_ nr
  exact ⟨k, eq, by omega⟩

theorem nmi_integer {s : Term} (start : NmiAtLeast s 0) :
    ∃ b0 : Int, s.get (a "next_message_id") = .integer b0 ∧ 0 ≤ b0 :=
  let ⟨m, hm, le⟩ := start
  ⟨m, hm, le⟩

/-! ## Host answers (H2) -/

/-- H2 for records: a record that the host builds carries integer `base` and
`aid` with `base ≤ aid`, and the `hwm` option of its intent commit covers
`aid`. The host builds `aid` as the next message id plus the activation
events, and the admission `hwm` from the projected intent. The kernel checks
`base` against the session. -/
def RecordsPositioned (cfg : HostConfig) : Prop :=
  ∀ w spec record, cfg.record w spec record →
    ∃ base aid hwm : Int, mkey record "base" = .integer base ∧ mkey record "aid" = .integer aid ∧
      base ≤ aid ∧ intentHwm record = .integer hwm ∧ aid ≤ hwm

/-! ## Machine invariants -/

/-- A machine in phase `notice_cleanup` holds a fresh notice aid. -/
def MachineFresh (log : List HostLabel) (base machine : Term) : Prop :=
  phaseIs machine "notice_cleanup" → FreshAid log base (mkey machine "notice_aid")

/-- A record event for a machine in phase `intent` is a record the host built. -/
def RecordKnown (cfg : HostConfig) (event machine : Term) : Prop :=
  ∀ record, event = .tuple [a "record", record] → phaseIs machine "intent" →
    ∃ w spec, cfg.record w spec record

theorem flags_aid (record planned progress : Term) :
    mkey (.map [(b "mode", b "model_turn"), (b "planned", planned), (b "aid", mkey record "aid"),
      (b "progress_event", progress)]) "aid" = mkey record "aid" := by
  simp (config := { decide := true }) only [mkey_map_head, mkey_map_skip]

theorem notice_flags_aid (machine : Term) :
    mkey (.map [(b "mode", b "runtime_failure_notice"), (b "aid", mkey machine "notice_aid")]) "aid" =
      mkey machine "notice_aid" := by
  simp (config := { decide := true }) only [mkey_map_head, mkey_map_skip]

theorem stepOK_facts {s m ev m' : Term} {effs : List Term} (step : StepOK Loop.queryAsk s m ev m' effs) :
    MachineFacts s m (.tuple [m', list effs]) := by
  obtain ⟨j, j', h⟩ := step
  exact step_facts h

/-- The dispatches of one committed step. The step read `s` and its commit
landed as `t`. Every `run_tools` aid is fresh after the landing, and a machine
in phase `notice_cleanup` holds a fresh aid. -/
theorem committed_fresh {cfg : HostConfig} (sources : StepSources) (h2 : RecordsPositioned cfg)
    {log : List HostLabel} {base s t m ev m' opts mode : Term} {effs events : List Term}
    (start : NmiAtLeast base 0) (reach : NmiStep base s)
    (kept : ∀ i aid, DispatchAt log i aid → Retracted log i ∨ AidBelow aid base)
    (machineOk : MachineFresh log base m) (recordOk : RecordKnown cfg ev m)
    (step : StepOK Loop.queryAsk s m ev m' effs) (commitIn : commitEffect events opts mode ∈ effs)
    (land : ResidentBatch s (landed events opts) t) :
    MachineFresh log t m' ∧ ∀ calls flags, runToolsEffect calls flags ∈ effs →
      FreshAid log t (mkey flags "aid") ∧ ¬phaseIs m' "notice_cleanup" := by
  have shape := sources.shape step
  have atS : NmiAtLeast s 0 := reach 0 start
  obtain ⟨b0, readS, nonneg⟩ := nmi_integer atS
  have keptS := keptBelow_of kept reach readS
  have baseT : NmiStep base t := nmi_trans reach (landed_nmi land)
  have facts := stepOK_facts step m' effs rfl
  refine ⟨fun hp => ?_, fun calls flags mem => ⟨?_, ?_⟩⟩
  · obtain ⟨source, _⟩ := facts.1 hp
    rcases source with ⟨events', aid, _, _, noticeIn, nextId, aidIs, _, _⟩ | ⟨pm, same, _⟩
    · obtain ⟨rfl, rfl, rfl⟩ := commit_unique shape commitIn noticeIn
      have aidEq : aid = .integer b0 := by rw [fieldIs_get nextId, readS]
      rw [fieldIs_get nextId, readS] at aidIs
      rw [aidIs]
      rw [aidEq] at land
      exact ⟨b0, rfl, keptS, landed_integer land nonneg atS⟩
    · rw [same]
      exact fresh_mono (machineOk pm) baseT
  · cases sources.dispatch step mem with
    | modelTurn record nmid progress entry phase nextId fresh checked =>
      rw [flags_aid]
      obtain ⟨w, spec, built⟩ := recordOk record entry phase
      obtain ⟨bb, n, h, hbase, haid, le, hhwm, le'⟩ := h2 w spec record built
      rw [fieldIs_get nextId, readS, hbase] at fresh
      have bb0 := integer_beq fresh
      subst bb0
      have intentIn := sources.intent (entry ▸ step) phase mem
      obtain ⟨rfl, rfl, rfl⟩ := commit_unique shape commitIn intentIn
      rw [hhwm] at land
      have above := landed_integer land (by omega) atS
      exact ⟨n, haid, keptBelow_le keptS le, above.mono (by omega)⟩
    | notice now events' entry cleanup authorized =>
      rw [notice_flags_aid]
      exact fresh_mono (machineOk entry.2) baseT
  · intro hp
    exact (facts.1 hp).2 calls flags (blocking_last shape (runTools_blocking calls flags) mem)

/-- The dispatches of one step without a commit. -/
theorem local_fresh (sources : StepSources)
    {log : List HostLabel} {base s m ev m' : Term} {effs : List Term}
    (machineOk : MachineFresh log base m)
    (step : StepOK Loop.queryAsk s m ev m' effs) (noCommit : NoCommit effs) :
    MachineFresh log base m' ∧ ∀ calls flags, runToolsEffect calls flags ∈ effs →
      FreshAid log base (mkey flags "aid") ∧ ¬phaseIs m' "notice_cleanup" := by
  have shape := sources.shape step
  have facts := stepOK_facts step m' effs rfl
  refine ⟨fun hp => ?_, fun calls flags mem => ⟨?_, ?_⟩⟩
  · rcases (facts.1 hp).1 with ⟨_, _, _, _, noticeIn, _, _, _, _⟩ | ⟨pm, same, _⟩
    · exact (noCommit _ _ _ noticeIn).elim
    · rw [same]
      exact machineOk pm
  · cases sources.dispatch step mem with
    | modelTurn record nmid progress entry phase nextId fresh checked =>
      exact (noCommit _ _ _ (sources.intent (entry ▸ step) phase mem)).elim
    | notice now events' entry cleanup authorized =>
      rw [notice_flags_aid]
      exact machineOk entry.2
  · intro hp
    exact (facts.1 hp).2 calls flags (blocking_last shape (runTools_blocking calls flags) mem)

/-! ## The freshness invariant -/

/-- Pending dispatch obligations of the host control. -/
def FreshControl (cfg : HostConfig) (log : List HostLabel) (base : Term) : Control → Prop
  | .idle => True
  | .feed machine event => MachineFresh log base machine ∧ RecordKnown cfg event machine
  | .perform machine effects => MachineFresh log base machine ∧
      ∀ calls flags, runToolsEffect calls flags ∈ effects →
        FreshAid log base (mkey flags "aid") ∧ ¬phaseIs machine "notice_cleanup"
  | .running machine _ => MachineFresh log base machine

/-- The invariant of `dispatch_at_most_once`. -/
structure FreshInv (cfg : HostConfig) (log : List HostLabel) (σ : HostState) : Prop where
  start : NmiAtLeast σ.baseline 0
  toDurable : NmiStep σ.baseline σ.durable
  toWorking : NmiStep σ.baseline σ.working
  kept : ∀ i aid, DispatchAt log i aid → Retracted log i ∨ AidBelow aid σ.baseline
  distinct : Distinct log
  control : FreshControl cfg log σ.baseline σ.control

theorem control_base {cfg : HostConfig} {log : List HostLabel} {base base' : Term} {c : Control}
    (ok : FreshControl cfg log base c) (step : NmiStep base base') : FreshControl cfg log base' c := by
  cases c with
  | idle => trivial
  | feed m ev => exact ⟨fun hp => fresh_mono (ok.1 hp) step, ok.2⟩
  | perform m effs =>
    refine ⟨fun hp => fresh_mono (ok.1 hp) step, fun calls flags mem => ?_⟩
    obtain ⟨fresh, notice⟩ := ok.2 calls flags mem
    exact ⟨fresh_mono fresh step, notice⟩
  | running m calls => exact fun hp => fresh_mono (ok hp) step

theorem control_log {cfg : HostConfig} {log extra : List HostLabel} {base : Term} {c : Control}
    (ok : FreshControl cfg log base c) (none : NoDispatch extra) : FreshControl cfg (log ++ extra) base c := by
  cases c with
  | idle => trivial
  | feed m ev => exact ⟨fun hp => fresh_log (ok.1 hp) none, ok.2⟩
  | perform m effs =>
    refine ⟨fun hp => fresh_log (ok.1 hp) none, fun calls flags mem => ?_⟩
    obtain ⟨fresh, notice⟩ := ok.2 calls flags mem
    exact ⟨fresh_log fresh none, notice⟩
  | running m calls => exact fun hp => fresh_log (ok hp) none

theorem kept_mono {log extra : List HostLabel} {base base' : Term}
    (kept : ∀ i aid, DispatchAt log i aid → Retracted log i ∨ AidBelow aid base)
    (step : NmiStep base base') (none : NoDispatch extra) :
    ∀ i aid, DispatchAt (log ++ extra) i aid → Retracted (log ++ extra) i ∨ AidBelow aid base' := by
  intro i aid at_
  obtain ⟨_, old⟩ := dispatchAt_none none at_
  rcases kept i aid old with r | ⟨k, eq, above⟩
  · exact Or.inl (retracted_mono r)
  · exact Or.inr ⟨k, eq, step _ above⟩

/-- A transition that adds no dispatch and moves the baseline forward. -/
theorem freshInv_frame {cfg : HostConfig} {log extra : List HostLabel} {σ σ' : HostState}
    (inv : FreshInv cfg log σ) (none : NoDispatch extra) (step : NmiStep σ.baseline σ'.baseline)
    (durable : NmiStep σ'.baseline σ'.durable) (working : NmiStep σ'.baseline σ'.working)
    (control : FreshControl cfg log σ'.baseline σ'.control) : FreshInv cfg (log ++ extra) σ' where
  start := step 0 inv.start
  toDurable := durable
  toWorking := working
  kept := kept_mono inv.kept step none
  distinct := distinct_none inv.distinct none
  control := control_log control none

theorem nil_not_phase (name : String) : ¬phaseIs nil name := by
  unfold phaseIs mkey
  intro h
  simp only [nil, Term.isMap, Bool.false_eq_true, ↓reduceIte] at h
  simp [b, Term.text] at h

theorem record_not_reply {cfg : HostConfig} {w effect event : Term} (answer : HostReply cfg w effect event)
    (machine : Term) : RecordKnown cfg event machine := by
  intro record eq
  cases answer <;> simp at eq

theorem record_not_tools {cfg : HostConfig} (machine results async : Term) :
    RecordKnown cfg (.tuple [a "tools_done", results, async]) machine := by
  intro record eq
  simp at eq

theorem record_not_continue {cfg : HostConfig} (machine : Term) : RecordKnown cfg (a "continue") machine := by
  intro record eq
  simp at eq

theorem mem_post {pre post : List Term} {x e : Term} (mem : e ∈ post) : e ∈ pre ++ x :: post :=
  List.mem_append_right _ (List.mem_cons_of_mem _ mem)

theorem mem_last {pre mid : List Term} {x e : Term} : e ∈ pre ++ x :: (mid ++ [e]) :=
  List.mem_append_right _ (List.mem_cons_of_mem _ (List.mem_append_right _ (List.mem_singleton_self _)))

/-- One host transition keeps the freshness invariant. -/
theorem freshInv_step {cfg : HostConfig} (sources : StepSources) (h2 : RecordsPositioned cfg)
    {log labels : List HostLabel} {σ σ' : HostState}
    (inv : FreshInv cfg log σ) (next : HostStep cfg σ labels σ') : FreshInv cfg (log ++ labels) σ' := by
  have ctl := inv.control
  cases next with
  | enter idle =>
    refine freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking ?_
    exact ⟨fun hp => (nil_not_phase _ hp).elim, fun _ _ hp => (nil_not_phase _ hp).elim⟩
  | request idle model granted =>
    refine freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking ?_
    exact ⟨fun hp => (nil_not_phase _ hp).elim, fun _ _ hp => (nil_not_phase _ hp).elim⟩
  | «local» feed step noCommit =>
    rw [feed] at ctl
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking
      (local_fresh sources ctl.1 step noCommit)
  | commit feed clean first step land =>
    rw [feed] at ctl
    have out := committed_fresh sources h2 inv.start inv.toDurable inv.kept ctl.1 ctl.2 step
      mem_of_commit_split land
    refine freshInv_frame inv (by no_dispatch) (nmi_trans inv.toDurable (landed_nmi land))
      (nmi_refl _) (nmi_refl _) ⟨out.1, fun calls flags mem => out.2 calls flags (mem_post mem)⟩
  | reroute feed clean first step noCommit =>
    rw [feed] at ctl
    exact freshInv_frame inv (by no_dispatch) inv.toDurable (nmi_refl _) (nmi_refl _)
      (control_base (local_fresh sources ctl.1 step noCommit) inv.toDurable)
  | fenceCommit feed dirty step notSpeculative land cas =>
    rw [feed] at ctl
    have out := committed_fresh sources h2 inv.start inv.toWorking inv.kept ctl.1 ctl.2 step
      mem_of_commit_split land
    refine freshInv_frame inv (by no_dispatch) (nmi_trans inv.toWorking (landed_nmi land))
      (nmi_refl _) (nmi_refl _) ⟨out.1, fun calls flags mem => out.2 calls flags (mem_post mem)⟩
  | @speculative machine event machine' t mode opts calls flags results async pre events mid
      feed step isSpeculative land executed cas =>
    rw [feed] at ctl
    have out := committed_fresh sources h2 inv.start inv.toWorking inv.kept ctl.1 ctl.2 step
      mem_of_commit_split land
    obtain ⟨fresh, notice⟩ := out.2 calls flags mem_last
    obtain ⟨n, eq, keptN, above⟩ := fresh
    have baseT : NmiStep σ.baseline t := nmi_trans inv.toWorking (landed_nmi land)
    have split : log ++ [HostLabel.written events, .dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true,
        .commit events mode, .toolsReturned results] =
        log ++ ([HostLabel.written events] ++ HostLabel.dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true ::
          [.commit events mode, .toolsReturned results]) := rfl
    refine ⟨baseT 0 inv.start, nmi_refl _, nmi_refl _, ?_, ?_, ?_⟩
    · intro i aid at_
      rw [split] at at_ ⊢
      rcases dispatchAt_split (by no_dispatch) (by no_dispatch) at_ with ⟨_, old⟩ | ⟨_, rfl⟩
      · rcases inv.kept i aid old with r | ⟨k, e, a'⟩
        · exact Or.inl (retracted_mono r)
        · exact Or.inr ⟨k, e, baseT _ a'⟩
      · exact Or.inr ⟨n, eq, above⟩
    · rw [split]
      exact distinct_extend inv.distinct eq keptN (by no_dispatch) (by no_dispatch)
    · exact ⟨fun hp => (notice hp).elim, record_not_tools _ _ _⟩
  | @speculativeFailed machine event machine' t mode opts calls flags pre events mid
      feed step isSpeculative land =>
    rw [feed] at ctl
    have out := committed_fresh sources h2 inv.start inv.toWorking inv.kept ctl.1 ctl.2 step
      mem_of_commit_split land
    obtain ⟨fresh, notice⟩ := out.2 calls flags mem_last
    obtain ⟨n, eq, keptN, above⟩ := fresh
    have split : log ++ [HostLabel.written events, .dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true,
        .failed] =
        log ++ ([HostLabel.written events] ++ HostLabel.dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true ::
          [.failed]) := rfl
    refine ⟨inv.start, inv.toDurable, nmi_refl _, ?_, ?_, trivial⟩
    · intro i aid at_
      rw [split] at at_ ⊢
      rcases dispatchAt_split (by no_dispatch) (by no_dispatch) at_ with ⟨_, old⟩ | ⟨pos, rfl⟩
      · rcases inv.kept i aid old with r | below
        · exact Or.inl (retracted_mono r)
        · exact Or.inr below
      · left
        subst pos
        refine ⟨⟨mkey flags "aid", σ.calls, mkey flags "mode", ?_⟩, ?_⟩
        · rw [List.getElem?_append_right (by simp)]
          simp
        · rw [List.getElem?_append_right (by simp; omega)]
          have : log.length + 1 + 1 - log.length = 2 := by omega
          simp [this]
    · rw [split]
      exact distinct_extend inv.distinct eq keptN (by no_dispatch) (by no_dispatch)
  | skip perform kind =>
    rw [perform] at ctl
    refine freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking
      ⟨ctl.1, fun calls flags mem => ctl.2 calls flags (List.mem_cons_of_mem _ mem)⟩
  | write perform land =>
    rw [perform] at ctl
    refine freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable
      (nmi_trans inv.toWorking (batch_nmi land))
      ⟨ctl.1, fun calls flags mem => ctl.2 calls flags (List.mem_cons_of_mem _ mem)⟩
  | reply perform answer =>
    rw [perform] at ctl
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking
      ⟨ctl.1, record_not_reply answer _⟩
  | record perform built =>
    rw [perform] at ctl
    refine freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking ⟨ctl.1, ?_⟩
    intro record eq _
    simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at eq
    subst eq
    exact ⟨_, _, built⟩
  | @dispatch machine calls flags perform =>
    rw [perform] at ctl
    obtain ⟨fresh, notice⟩ := ctl.2 calls flags (List.mem_singleton_self _)
    obtain ⟨n, eq, keptN, above⟩ := fresh
    have split : log ++ [HostLabel.dispatch (mkey flags "aid") calls (mkey flags "mode") false] =
        log ++ ([] ++ HostLabel.dispatch (mkey flags "aid") calls (mkey flags "mode") false :: []) := rfl
    refine ⟨inv.start, inv.toDurable, inv.toWorking, ?_, ?_, fun hp => (notice hp).elim⟩
    · intro i aid at_
      rw [split] at at_ ⊢
      rcases dispatchAt_split noDispatch_nil noDispatch_nil at_ with ⟨_, old⟩ | ⟨_, rfl⟩
      · rcases inv.kept i aid old with r | below
        · exact Or.inl (retracted_mono r)
        · exact Or.inr below
      · exact Or.inr ⟨n, eq, above⟩
    · rw [split]
      exact distinct_extend inv.distinct eq keptN noDispatch_nil noDispatch_nil
  | returned running executed =>
    rw [running] at ctl
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking
      ⟨ctl, record_not_tools _ _ _⟩
  | planned perform =>
    rw [perform] at ctl
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking
      ⟨ctl.1, record_not_continue _⟩
  | materialize perform plan land =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable
      (nmi_trans inv.toWorking (batch_nmi land)) trivial
  | materializeRun perform plan land =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable
      (nmi_trans inv.toWorking (batch_nmi land)) trivial
  | fast idle plan land =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable
      (nmi_trans inv.toWorking (batch_nmi land)) (by rw [idle] at ctl ⊢; trivial)
  | stop perform =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable inv.toWorking trivial
  | fence idle dirty cas =>
    rw [idle] at ctl
    exact freshInv_frame inv (by no_dispatch) inv.toWorking (nmi_refl _) (nmi_refl _) (by rw [idle]; trivial)
  | refresh clean =>
    exact freshInv_frame inv (by no_dispatch) inv.toDurable (nmi_refl _) (nmi_refl _)
      (control_base ctl inv.toDurable)
  | env plan land =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) (nmi_trans inv.toDurable (batch_nmi land))
      inv.toWorking ctl
  | abort busy =>
    exact freshInv_frame inv (by no_dispatch) (nmi_refl _) inv.toDurable (nmi_refl _) trivial
  | crash =>
    exact freshInv_frame inv (by no_dispatch) inv.toDurable (nmi_refl _) (nmi_refl _) trivial
  | restart idle clean plan land =>
    exact freshInv_frame inv (by no_dispatch) (nmi_trans inv.toDurable (batch_nmi land))
      (nmi_refl _) (nmi_refl _) (by rw [idle] at ctl ⊢; trivial)

/-! ## Runs -/

theorem freshInv_init {cfg : HostConfig} {σ : HostState} (init : HostInit σ) (start : NmiAtLeast σ.durable 0) :
    FreshInv cfg [] σ := by
  obtain ⟨idle, working, baseline, _⟩ := init
  refine ⟨by rw [baseline]; exact start, by rw [baseline]; exact nmi_refl _,
    by rw [baseline, working]; exact nmi_refl _, ?_, ?_, by rw [idle]; trivial⟩
  · intro i aid ⟨_, _, _, h⟩
    simp at h
  · intro i j aid _ ⟨_, _, _, h⟩
    simp at h

theorem freshInv_run {cfg : HostConfig} (sources : StepSources) (h2 : RecordsPositioned cfg)
    {σ₀ σ : HostState} {log : List HostLabel} (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀)
    (start : NmiAtLeast σ₀.durable 0) : FreshInv cfg log σ := by
  induction run with
  | refl => exact freshInv_init init start
  | step _ next ih => exact freshInv_step sources h2 ih next

/-! ## Intent tracking -/

/-! ### Round events of labels -/

/-- The `AgentLoop.Round` events that a label acknowledges. A durable intent
commit (the only commit with a map mode) starts the round and acknowledges the
intent. Returned tools acknowledge execution. Another durable commit or the
end of `commit_planned_results` acknowledges results. A failure or a crash
fails the round. -/
def roundEvent : HostLabel → List AgentLoop.Round.Event
  | .commit _ mode => if mode.isMap then [.start, .committed] else [.committed]
  | .toolsReturned _ => [.executed]
  | .plannedCommitted => [.committed]
  | .failed => [.failed]
  | .crash => [.failed]
  | _ => []

/-- A label that feeds no round event, starts no round and dispatches nothing. -/
def Quiet (label : HostLabel) : Prop :=
  roundEvent label = [] ∧ (∀ event, label ≠ .enter event) ∧ ∀ aid calls mode spec, label ≠ .dispatch aid calls mode spec

/-- Every label strictly between positions `k` and `i` is quiet. -/
def QuietGap (log : List HostLabel) (k i : Nat) : Prop :=
  ∀ q, k < q → q < i → ∃ label, log[q]? = some label ∧ Quiet label

/-- A durable commit of the intent record for `aid` and `calls` precedes position
`i`, and only quiet labels lie between them. -/
def DurableIntentBefore (cfg : HostConfig) (log : List HostLabel) (i : Nat) (aid calls : Term) : Prop :=
  ∃ k < i, ∃ spec record w, log[k]? = some (.commit (intentEvents record) (intentMode record)) ∧
    (∃ j < k, log[j]? = some (.record spec record)) ∧ cfg.record w spec record ∧
    mkey record "aid" = aid ∧ mkey spec "calls" = calls ∧ mkey spec "mode" = b "tools" ∧ QuietGap log k i

/-- The working write of a speculative intent record for `aid` and `calls` is at
position `i - 1`. -/
def WrittenIntentBefore (cfg : HostConfig) (log : List HostLabel) (i : Nat) (aid calls : Term) : Prop :=
  ∃ k, k + 1 = i ∧ ∃ spec record w, log[k]? = some (.written (intentEvents record)) ∧
    (∃ j < k, log[j]? = some (.record spec record)) ∧ cfg.record w spec record ∧
    mkey record "aid" = aid ∧ mkey spec "calls" = calls ∧ mkey spec "mode" = b "tools" ∧
    (mkey record "speculative").truthy = true

/-- A record event for a machine in phase `intent` is the last record label,
and `host.calls` and the machine calls are the calls of its spec. -/
def RecordTracked (cfg : HostConfig) (log : List HostLabel) (hostCalls event machine : Term) : Prop :=
  ∀ record, event = .tuple [a "record", record] → phaseIs machine "intent" →
    ∃ j < log.length, ∃ w spec, log[j]? = some (.record spec record) ∧ cfg.record w spec record ∧
      mkey spec "mode" = b "tools" ∧ mkey spec "calls" = mkey machine "calls" ∧ hostCalls = mkey machine "calls"

def IntentControl (cfg : HostConfig) (log : List HostLabel) (hostCalls : Term) : Control → Prop
  | .idle => True
  | .feed machine event => RecordTracked cfg log hostCalls event machine
  | .perform machine effects =>
      (∀ spec, effects.getLast? = some (.tuple [a "build_record", spec]) → phaseIs machine "intent" →
        mkey spec "mode" = b "tools" ∧ mkey spec "calls" = mkey machine "calls") ∧
      ∀ calls flags, runToolsEffect calls flags ∈ effects → mkey flags "mode" = b "model_turn" →
        DurableIntentBefore cfg log log.length (mkey flags "aid") calls
  | .running _ _ => True

/-- The invariant of `dispatch_after_durable_intent` and `speculative_dispatch`. -/
structure IntentInv (cfg : HostConfig) (log : List HostLabel) (σ : HostState) : Prop where
  durable : ∀ i aid calls, log[i]? = some (.dispatch aid calls (b "model_turn") false) →
    DurableIntentBefore cfg log i aid calls
  speculative : ∀ i aid calls mode, log[i]? = some (.dispatch aid calls mode true) →
    WrittenIntentBefore cfg log i aid calls
  control : IntentControl cfg log σ.calls σ.control

theorem quietGap_mono {log extra : List HostLabel} {k i : Nat} (gap : QuietGap log k i) :
    QuietGap (log ++ extra) k i := by
  intro q lo hi
  obtain ⟨label, at_, quiet⟩ := gap q lo hi
  exact ⟨label, getElem?_old at_, quiet⟩

theorem durable_mono {cfg : HostConfig} {log extra : List HostLabel} {i : Nat} {aid calls : Term}
    (h : DurableIntentBefore cfg log i aid calls) : DurableIntentBefore cfg (log ++ extra) i aid calls := by
  obtain ⟨k, lt, spec, record, w, at_, ⟨j, lj, atj⟩, a1, a2, a3, a4, gap⟩ := h
  exact ⟨k, lt, spec, record, w, getElem?_old at_, ⟨j, lj, getElem?_old atj⟩, a1, a2, a3, a4, quietGap_mono gap⟩

theorem written_mono {cfg : HostConfig} {log extra : List HostLabel} {i : Nat} {aid calls : Term}
    (h : WrittenIntentBefore cfg log i aid calls) : WrittenIntentBefore cfg (log ++ extra) i aid calls := by
  obtain ⟨k, eq, spec, record, w, at_, ⟨j, lj, atj⟩, rest⟩ := h
  exact ⟨k, eq, spec, record, w, getElem?_old at_, ⟨j, lj, getElem?_old atj⟩, rest⟩

theorem tracked_mono {cfg : HostConfig} {log extra : List HostLabel} {c event machine : Term}
    (h : RecordTracked cfg log c event machine) : RecordTracked cfg (log ++ extra) c event machine := by
  intro record eq phase
  obtain ⟨j, lj, w, spec, at_, rest⟩ := h record eq phase
  exact ⟨j, by simp; omega, w, spec, getElem?_old at_, rest⟩

/-- A pending intent obligation survives quiet labels. -/
theorem durable_extend {cfg : HostConfig} {log extra : List HostLabel} {aid calls : Term}
    (h : DurableIntentBefore cfg log log.length aid calls) (quiet : ∀ l ∈ extra, Quiet l) :
    DurableIntentBefore cfg (log ++ extra) (log ++ extra).length aid calls := by
  obtain ⟨k, lt, spec, record, w, at_, recordAt, a1, a2, a3, a4, gap⟩ := h
  refine ⟨k, by simp; omega, spec, record, w, getElem?_old at_, ?_, a1, a2, a3, a4, ?_⟩
  · obtain ⟨j, lj, atj⟩ := recordAt
    exact ⟨j, lj, getElem?_old atj⟩
  · intro q lo hi
    by_cases small : q < log.length
    · obtain ⟨label, at', quiet'⟩ := gap q lo small
      exact ⟨label, getElem?_old at', quiet'⟩
    · have within : q - log.length < extra.length := by simp at hi; omega
      refine ⟨extra[q - log.length], ?_, quiet _ (List.getElem_mem within)⟩
      rw [List.getElem?_append_right (Nat.le_of_not_lt small)]
      exact List.getElem?_eq_getElem within

theorem intentControl_mono {cfg : HostConfig} {log extra : List HostLabel} {c : Term} {ctl : Control}
    (h : IntentControl cfg log c ctl) (quiet : ∀ l ∈ extra, Quiet l) :
    IntentControl cfg (log ++ extra) c ctl := by
  cases ctl with
  | idle => trivial
  | feed m ev => exact tracked_mono h
  | perform m effs =>
    exact ⟨h.1, fun calls flags mem mode => durable_extend (h.2 calls flags mem mode) quiet⟩
  | running => trivial

theorem notice_mode (machine : Term) :
    mkey (.map [(b "mode", b "runtime_failure_notice"), (b "aid", mkey machine "notice_aid")]) "mode" ≠
      b "model_turn" := by
  rw [mkey_map_head]
  intro h
  have := text_inj.mp h
  simp at this

theorem model_mode (record planned progress : Term) :
    mkey (.map [(b "mode", b "model_turn"), (b "planned", planned), (b "aid", mkey record "aid"),
      (b "progress_event", progress)]) "mode" = b "model_turn" := by
  simp only [mkey_map_head]

/-- No model-turn dispatch in a step without a commit. -/
theorem local_no_model (sources : StepSources) {s m ev m' calls flags : Term} {effs : List Term}
    (step : StepOK Loop.queryAsk s m ev m' effs) (noCommit : NoCommit effs)
    (mem : runToolsEffect calls flags ∈ effs) : mkey flags "mode" ≠ b "model_turn" := by
  cases sources.dispatch step mem with
  | modelTurn record nmid progress entry phase nextId fresh checked =>
    exact (noCommit _ _ _ (sources.intent (entry ▸ step) phase mem)).elim
  | notice now events entry cleanup authorized => exact notice_mode _

/-- The model-turn dispatch of a committed step: its commit is the intent of
the tracked record. -/
theorem committed_intent {cfg : HostConfig} (sources : StepSources) {log : List HostLabel}
    {hostCalls s m ev m' opts mode calls flags : Term} {events effs : List Term}
    (tracked : RecordTracked cfg log hostCalls ev m) (step : StepOK Loop.queryAsk s m ev m' effs)
    (commitIn : commitEffect events opts mode ∈ effs) (mem : runToolsEffect calls flags ∈ effs)
    (model : mkey flags "mode" = b "model_turn") :
    ∃ j < log.length, ∃ w spec record, log[j]? = some (.record spec record) ∧ cfg.record w spec record ∧
      events = intentEvents record ∧ mode = intentMode record ∧ mkey record "aid" = mkey flags "aid" ∧
      mkey spec "calls" = calls ∧ mkey spec "mode" = b "tools" ∧
      (specMode mode = true → hostCalls = calls ∧ (mkey record "speculative").truthy = true) := by
  cases sources.dispatch step mem with
  | modelTurn record nmid progress entry phase nextId fresh checked =>
    obtain ⟨j, lj, w, spec, at_, built, tools, calls_, host⟩ := tracked record entry phase
    have intentIn := sources.intent (entry ▸ step) phase mem
    obtain ⟨rfl, rfl, rfl⟩ := commit_unique (sources.shape step) commitIn intentIn
    refine ⟨j, lj, w, spec, record, at_, built, rfl, rfl, (flags_aid _ _ _).symm, calls_, tools, ?_⟩
    intro speculative
    refine ⟨host, ?_⟩
    simp only [specMode, intentMode, Term.isMap, Bool.true_and] at speculative
    simp (config := { decide := true }) only [Term.get, List.find?, binary_key_beq, Option.map,
      Option.getD] at speculative
    cases h : (mkey record "speculative").truthy
    · rw [h] at speculative
      simp [Term.bool, BEq.beq] at speculative
    · rfl
  | notice now events entry cleanup authorized => exact absurd model (notice_mode _)

theorem last_post {pre post : List Term} {c x : Term} (h : post.getLast? = some x) :
    (pre ++ c :: post).getLast? = some x := by
  rw [List.getLast?_append, List.getLast?_cons, h]
  rfl

theorem facts_post {s m m' : Term} {pre post : List Term} {c : Term}
    (facts : MachineFacts s m (.tuple [m', list (pre ++ c :: post)])) :
    ∀ spec, post.getLast? = some (.tuple [a "build_record", spec]) → phaseIs m' "intent" →
      mkey spec "mode" = b "tools" ∧ mkey spec "calls" = mkey m' "calls" :=
  fun spec last => (facts m' _ rfl).2 spec (last_post last)

/-- A transition whose labels contain no dispatch. -/
theorem intentInv_frame {cfg : HostConfig} {log extra : List HostLabel} {σ σ' : HostState}
    (inv : IntentInv cfg log σ) (none : NoDispatch extra)
    (control : IntentControl cfg (log ++ extra) σ'.calls σ'.control) : IntentInv cfg (log ++ extra) σ' where
  durable := by
    intro i aid calls at_
    obtain ⟨small, _⟩ := dispatchAt_none none ⟨calls, _, _, at_⟩
    rw [List.getElem?_append_left small] at at_
    exact durable_mono (inv.durable i aid calls at_)
  speculative := by
    intro i aid calls mode at_
    obtain ⟨small, _⟩ := dispatchAt_none none ⟨calls, mode, _, at_⟩
    rw [List.getElem?_append_left small] at at_
    exact written_mono (inv.speculative i aid calls mode at_)
  control := control

/-- Local steps: the new perform control has no model-turn dispatch. -/
theorem perform_local {cfg : HostConfig} (sources : StepSources) {log : List HostLabel} {c s m ev m' : Term}
    {effs : List Term} (step : StepOK Loop.queryAsk s m ev m' effs) (noCommit : NoCommit effs) :
    IntentControl cfg log c (.perform m' effs) := by
  refine ⟨(stepOK_facts step m' effs rfl).2, fun calls flags mem model => ?_⟩
  exact absurd model (local_no_model sources step noCommit mem)

/-- The `run_tools` of a speculative commit step is a model turn. -/
theorem speculative_model (sources : StepSources) {s m ev m' opts mode calls flags : Term}
    {events effs : List Term} (step : StepOK Loop.queryAsk s m ev m' effs)
    (commitIn : commitEffect events opts mode ∈ effs) (speculative : specMode mode = true)
    (mem : runToolsEffect calls flags ∈ effs) : mkey flags "mode" = b "model_turn" := by
  cases sources.dispatch step mem with
  | modelTurn record nmid progress entry phase nextId fresh checked => exact model_mode _ _ _
  | notice now events' entry cleanup authorized =>
    exfalso
    cases sources.commit step commitIn with
    | intent record nmid entry' => rw [entry.1] at entry'; cases entry'
    | _ => simp [specMode, nil, Term.isMap] at speculative

theorem label_split {log extra : List HostLabel} {i : Nat} {x : HostLabel} (h : (log ++ extra)[i]? = some x) :
    (i < log.length ∧ log[i]? = some x) ∨ ∃ d, i = log.length + d ∧ extra[d]? = some x := by
  by_cases small : i < log.length
  · rw [List.getElem?_append_left small] at h
    exact Or.inl ⟨small, h⟩
  · rw [List.getElem?_append_right (Nat.le_of_not_lt small)] at h
    exact Or.inr ⟨i - log.length, by omega, h⟩

/-- One host transition keeps the intent invariant. -/
theorem intentInv_step {cfg : HostConfig} (sources : StepSources)
    {log labels : List HostLabel} {σ σ' : HostState}
    (inv : IntentInv cfg log σ) (next : HostStep cfg σ labels σ') : IntentInv cfg (log ++ labels) σ' := by
  have ctl := inv.control
  cases next with
  | enter idle =>
    refine intentInv_frame inv (by no_dispatch) ?_
    intro record eq phase
    exact (nil_not_phase _ phase).elim
  | request idle model granted =>
    refine intentInv_frame inv (by no_dispatch) ?_
    intro record eq phase
    exact (nil_not_phase _ phase).elim
  | «local» feed step noCommit => exact intentInv_frame inv (by no_dispatch) (perform_local sources step noCommit)
  | commit feed clean first step land =>
    rw [feed] at ctl
    refine intentInv_frame inv (by no_dispatch) ⟨facts_post (stepOK_facts step), ?_⟩
    intro calls flags mem model
    obtain ⟨j, lj, w, spec, record, at_, built, rfl, rfl, aid, calls_, tools, _⟩ :=
      committed_intent sources ctl step mem_of_commit_split (mem_post mem) model
    exact ⟨log.length, by simp, spec, record, w, by simp, ⟨j, lj, getElem?_old at_⟩, built, aid, calls_, tools,
      fun q lo hi => by simp at hi; omega⟩
  | reroute feed clean first step noCommit =>
    exact intentInv_frame inv (by no_dispatch) (perform_local sources step noCommit)
  | fenceCommit feed dirty step notSpeculative land cas =>
    rw [feed] at ctl
    refine intentInv_frame inv (by no_dispatch) ⟨facts_post (stepOK_facts step), ?_⟩
    intro calls flags mem model
    obtain ⟨j, lj, w, spec, record, at_, built, rfl, rfl, aid, calls_, tools, _⟩ :=
      committed_intent sources ctl step mem_of_commit_split (mem_post mem) model
    exact ⟨log.length, by simp, spec, record, w, by simp, ⟨j, lj, getElem?_old at_⟩, built, aid, calls_, tools,
      fun q lo hi => by simp at hi; omega⟩
  | @speculative machine event machine' t mode opts calls flags results async pre events mid
      feed step isSpeculative land executed cas =>
    rw [feed] at ctl
    have model := speculative_model sources step mem_of_commit_split isSpeculative mem_last
    obtain ⟨j, lj, w, spec, record, at_, built, rfl, rfl, aid, calls_, tools, spec_⟩ :=
      committed_intent sources ctl step mem_of_commit_split mem_last model
    obtain ⟨host, truthy⟩ := spec_ isSpeculative
    refine ⟨?_, ?_, fun record eq _ => by simp at eq⟩
    · intro i aid' calls' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact durable_mono (inv.durable i aid' calls' old)
      · rcases d with _ | _ | _ | _ | d <;> simp at new
    · intro i aid' calls' mode' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact written_mono (inv.speculative i aid' calls' mode' old)
      · rcases d with _ | _ | _ | _ | d <;> simp at new
        obtain ⟨rfl, rfl, rfl⟩ := new
        refine ⟨log.length, rfl, spec, record, w, by simp, ⟨j, lj, getElem?_old at_⟩, built, aid,
          by rw [calls_, host], tools, truthy⟩
  | @speculativeFailed machine event machine' t mode opts calls flags pre events mid
      feed step isSpeculative land =>
    rw [feed] at ctl
    have model := speculative_model sources step mem_of_commit_split isSpeculative mem_last
    obtain ⟨j, lj, w, spec, record, at_, built, rfl, rfl, aid, calls_, tools, spec_⟩ :=
      committed_intent sources ctl step mem_of_commit_split mem_last model
    obtain ⟨host, truthy⟩ := spec_ isSpeculative
    refine ⟨?_, ?_, trivial⟩
    · intro i aid' calls' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact durable_mono (inv.durable i aid' calls' old)
      · rcases d with _ | _ | _ | d <;> simp at new
    · intro i aid' calls' mode' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact written_mono (inv.speculative i aid' calls' mode' old)
      · rcases d with _ | _ | _ | d <;> simp at new
        obtain ⟨rfl, rfl, rfl⟩ := new
        refine ⟨log.length, rfl, spec, record, w, by simp, ⟨j, lj, getElem?_old at_⟩, built, aid,
          by rw [calls_, host], tools, truthy⟩
  | skip perform kind =>
    rw [perform] at ctl
    refine intentInv_frame inv noDispatch_nil ⟨fun spec last phase => ?_, fun calls flags mem model => ?_⟩
    · refine ctl.1 spec ?_ phase
      rw [List.getLast?_cons, last]
      rfl
    · simpa using durable_extend (extra := []) (ctl.2 calls flags (List.mem_cons_of_mem _ mem) model) (by simp)
  | write perform land =>
    rw [perform] at ctl
    refine intentInv_frame inv (by no_dispatch) ⟨fun spec last phase => ?_, fun calls flags mem model => ?_⟩
    · refine ctl.1 spec ?_ phase
      rw [List.getLast?_cons, last]
      rfl
    · exact durable_extend (ctl.2 calls flags (List.mem_cons_of_mem _ mem) model)
        (by simp [Quiet, roundEvent])
  | reply perform answer =>
    refine intentInv_frame inv noDispatch_nil ?_
    intro record eq _
    cases answer <;> simp at eq
  | @record machine spec record perform built =>
    rw [perform] at ctl
    refine intentInv_frame inv (by no_dispatch) ?_
    intro record' eq phase
    simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at eq
    subst eq
    obtain ⟨tools, calls_⟩ := ctl.1 spec rfl phase
    refine ⟨log.length, by simp, _, spec, by simp, built, tools, calls_, ?_⟩
    simp only [tools, beq_self_eq_true, ↓reduceIte]
    exact calls_
  | @dispatch machine calls flags perform =>
    rw [perform] at ctl
    refine ⟨?_, ?_, trivial⟩
    · intro i aid' calls' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact durable_mono (inv.durable i aid' calls' old)
      · rcases d with _ | d <;> simp at new
        obtain ⟨rfl, rfl, model⟩ := new
        exact durable_mono (ctl.2 _ _ (List.mem_singleton_self _) model)
    · intro i aid' calls' mode' at_'
      rcases label_split at_' with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact written_mono (inv.speculative i aid' calls' mode' old)
      · rcases d with _ | d <;> simp at new
  | returned running executed =>
    refine intentInv_frame inv (by no_dispatch) ?_
    intro record eq _
    simp at eq
  | planned perform =>
    refine intentInv_frame inv (by no_dispatch) ?_
    intro record eq _
    simp at eq
  | materialize perform plan land => exact intentInv_frame inv (by no_dispatch) trivial
  | materializeRun perform plan land => exact intentInv_frame inv (by no_dispatch) trivial
  | fast idle plan land => exact intentInv_frame inv (by no_dispatch) (by rw [idle] at ctl ⊢; trivial)
  | stop perform => exact intentInv_frame inv (by no_dispatch) trivial
  | fence idle dirty cas =>
    exact intentInv_frame inv (by no_dispatch) (by rw [idle]; trivial)
  | refresh clean => exact intentInv_frame inv noDispatch_nil (intentControl_mono ctl (by simp))
  | env plan land =>
    exact intentInv_frame inv (by no_dispatch) (intentControl_mono ctl (by simp [Quiet, roundEvent]))
  | abort busy => exact intentInv_frame inv (by no_dispatch) trivial
  | crash => exact intentInv_frame inv (by no_dispatch) trivial
  | restart idle clean plan land =>
    exact intentInv_frame inv (by no_dispatch) (by rw [idle] at ctl ⊢; trivial)

/-! ## Step sources from `Loop/Shape.lean` -/

theorem mem_of_head {α : Type} {xs : List α} {x : α} (h : xs.head? = some x) : x ∈ xs := by
  cases xs with
  | nil => simp at h
  | cons y ys =>
    simp only [List.head?_cons, Option.some.injEq] at h
    subst h
    exact List.mem_cons_self


theorem stepSources : StepSources where
  shape := by
    intro s m ev m' effs step
    obtain ⟨j, j', h⟩ := step
    obtain ⟨m'', effs', same, shape⟩ := step_shape h
    cases result_inj same
    exact shape
  dispatch := step_dispatch_source
  commit := step_commit_source
  intent := by
    intro s m m' record calls flags effs step _ mem
    exact mem_of_head (step_dispatch_after_commit step mem)

/-! ## Intent runs -/

theorem intentInv_init {cfg : HostConfig} {σ : HostState} (init : HostInit σ) : IntentInv cfg [] σ := by
  refine ⟨fun i aid calls h => by simp at h, fun i aid calls mode h => by simp at h, ?_⟩
  rw [init.1]
  trivial

theorem intentInv_run {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) : IntentInv cfg log σ := by
  induction run with
  | refl => exact intentInv_init init
  | step _ next ih => exact intentInv_step stepSources ih next

/-! ## Property B -/

/-- B2: dispatches never share an assistant message id. The only exception is a
speculative dispatch whose durable fence failed: its intent never became
durable, so a later round can dispatch at the same id again. H4 makes such
calls read-only.

Hypotheses: the run starts from `HostInit` with an integer, non-negative
`next_message_id` (a new session has 1), and H2 (`RecordsPositioned`). -/
theorem dispatch_at_most_once {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) (start : NmiAtLeast σ₀.durable 0)
    (h2 : RecordsPositioned cfg) {i j : Nat} {aid : Term} (lt : i < j)
    (first : DispatchAt log i aid) (second : DispatchAt log j aid) : Retracted log i :=
  (freshInv_run stepSources h2 run init start).distinct i j aid lt first second

/-- The dispatch key of a label: the assistant message id and the mode. -/
def dispatchKey : HostLabel → Option (Term × Term)
  | .dispatch aid _ mode _ => some (aid, mode)
  | _ => none

theorem filterMap_nodup {α β : Type} (f : α → Option β) (xs : List α)
    (distinct : ∀ (i j : Nat) (x : β), i < j → (xs[i]?).bind f = some x → (xs[j]?).bind f = some x → False) :
    (xs.filterMap f).Nodup := by
  induction xs with
  | nil => simp
  | cons y ys ih =>
    have rest : (ys.filterMap f).Nodup := ih (fun i j x lt hi hj =>
      distinct (i + 1) (j + 1) x (by omega) (by simpa using hi) (by simpa using hj))
    cases hy : f y with
    | none => simpa [List.filterMap_cons, hy] using rest
    | some x =>
      simp only [List.filterMap_cons, hy, List.nodup_cons]
      refine ⟨fun mem => ?_, rest⟩
      obtain ⟨z, zmem, hz⟩ := List.mem_filterMap.mp mem
      obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem zmem
      exact distinct 0 (k + 1) x (by omega) (by simpa using hy) (by simp [List.getElem?_eq_getElem hk, hz])

/-- B2 as the issue states it: without a failed speculative fence, the
dispatch keys `(aid, mode)` of the log are pairwise distinct. -/
theorem dispatch_keys_nodup {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) (start : NmiAtLeast σ₀.durable 0)
    (h2 : RecordsPositioned cfg) (fenced : ∀ i, ¬Retracted log i) :
    (log.filterMap dispatchKey).Nodup := by
  apply filterMap_nodup
  intro i j key lt hi hj
  cases hx : log[i]? with
  | none => simp [hx] at hi
  | some x =>
    cases hy : log[j]? with
    | none => simp [hy] at hj
    | some y =>
      rw [hx] at hi
      rw [hy] at hj
      cases x with
      | dispatch aid₁ calls₁ mode₁ spec₁ =>
        cases y with
        | dispatch aid₂ calls₂ mode₂ spec₂ =>
          simp only [Option.bind_some, dispatchKey, Option.some.injEq] at hi hj
          have same : aid₁ = aid₂ := by rw [← hj] at hi; exact (Prod.mk.inj hi).1
          subst same
          exact fenced i (dispatch_at_most_once run init start h2 lt ⟨_, _, _, hx⟩ ⟨_, _, _, hy⟩)
        | _ => simp [dispatchKey] at hj
      | _ => simp [dispatchKey] at hi

/-- B1: a non-speculative model-turn dispatch at position `i` follows a durable
commit, at `k < i`, of the intent events of the record that the host built for
the same `aid`, and the dispatched calls are the calls of that record's spec.
This needs no host assumption beyond the model. -/
theorem dispatch_after_durable_intent {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {i : Nat} {aid calls : Term}
    (at_ : log[i]? = some (.dispatch aid calls (b "model_turn") false)) :
    ∃ k < i, ∃ spec record w, log[k]? = some (.commit (intentEvents record) (intentMode record)) ∧
      (∃ j < k, log[j]? = some (.record spec record)) ∧ cfg.record w spec record ∧
      mkey record "aid" = aid ∧ mkey spec "calls" = calls ∧ mkey spec "mode" = b "tools" := by
  obtain ⟨k, lt, spec, record, w, commit, recordAt, built, aidIs, callsIs, tools, _⟩ :=
    (intentInv_run run init).durable i aid calls at_
  exact ⟨k, lt, spec, record, w, commit, recordAt, built, aidIs, callsIs, tools⟩

/-- The calls that the assistant record holds: the model's own calls when the
kernel unwrapped a reply, else the dispatched calls (`spec["record_calls"] || calls`). -/
def recordedCalls (spec : Term) : Term :=
  if (mkey spec "record_calls").truthy then mkey spec "record_calls" else mkey spec "calls"

/-- H2 for record contents: the intent of a tool record holds the assistant
event at `aid` with the recorded calls (`assistant_commit_events`). -/
def RecordsCarryAssistant (cfg : HostConfig) : Prop :=
  ∀ w spec record, cfg.record w spec record → mkey spec "mode" = b "tools" →
    ∃ e ∈ wrap (mkey record "intent"), e.get (b "type") = b "assistant" ∧
      e.get (b "message_id") = mkey record "aid" ∧ e.get (b "tool_calls") = recordedCalls spec

/-- B1 with H2: the durable commit before a model-turn dispatch holds the
assistant event at the dispatch `aid`. -/
theorem dispatch_after_durable_assistant {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) (h2 : RecordsCarryAssistant cfg)
    {i : Nat} {aid calls : Term} (at_ : log[i]? = some (.dispatch aid calls (b "model_turn") false)) :
    ∃ k < i, ∃ events mode spec, log[k]? = some (.commit events mode) ∧ mkey spec "calls" = calls ∧
      ∃ e ∈ events, e.get (b "type") = b "assistant" ∧ e.get (b "message_id") = aid ∧
        e.get (b "tool_calls") = recordedCalls spec := by
  obtain ⟨k, lt, spec, record, w, commit, _, built, aidIs, callsIs, tools⟩ :=
    dispatch_after_durable_intent run init at_
  obtain ⟨e, mem, kind, id, recorded⟩ := h2 w spec record built tools
  refine ⟨k, lt, _, _, spec, commit, callsIs, e, ?_, kind, id.trans aidIs, recorded⟩
  unfold intentEvents
  exact List.mem_append_left _ mem

/-- H4: the host sets the speculative flag of a record only for read-only calls. -/
def SpeculativeReadOnly (cfg : HostConfig) (ReadOnly : Term → Prop) : Prop :=
  ∀ w spec record, cfg.record w spec record → (mkey record "speculative").truthy = true →
    ReadOnly (mkey spec "calls")

/-- B3: a speculative dispatch at position `i` directly follows the working
write of the intent of the record for the same `aid` and calls. The calls are
read-only by H4. The write is not durable yet: the next label is the fence
result, a durable `commit` or `failed`. -/
theorem speculative_dispatch {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {ReadOnly : Term → Prop}
    (h4 : SpeculativeReadOnly cfg ReadOnly)
    {i : Nat} {aid calls mode : Term} (at_ : log[i]? = some (.dispatch aid calls mode true)) :
    ReadOnly calls ∧ ∃ k, k + 1 = i ∧ ∃ spec record w, log[k]? = some (.written (intentEvents record)) ∧
      (∃ j < k, log[j]? = some (.record spec record)) ∧ cfg.record w spec record ∧
      mkey record "aid" = aid ∧ mkey spec "calls" = calls ∧ mkey spec "mode" = b "tools" := by
  obtain ⟨k, eq, spec, record, w, written, recordAt, built, aidIs, callsIs, tools, truthy⟩ :=
    (intentInv_run run init).speculative i aid calls mode at_
  exact ⟨callsIs ▸ h4 w spec record built truthy,
    k, eq, spec, record, w, written, recordAt, built, aidIs, callsIs, tools⟩

/-! ## Round state of the machine -/

/-- The round state of a machine, as the kernel decodes its `rstate`. -/
def roundOf (machine : Term) : AgentLoop.Round.State := decodeRoundOf (mkey machine "rstate")

/-- A kernel step on a machine that has left `ready` keeps it out of `ready`. -/
def RoundFacts (machine out : Term) : Prop :=
  ∀ machine' effects, out = .tuple [machine', list effects] →
    roundOf machine ≠ .ready → roundOf machine' ≠ .ready

theorem step_not_ready {s : AgentLoop.Round.State} (e : AgentLoop.Round.Event) (h : s ≠ .ready) :
    (AgentLoop.Round.step s e).1 ≠ .ready := by
  cases s <;> cases e <;> simp_all [AgentLoop.Round.step]

theorem roundOf_advance {m m' : Term} {event : AgentLoop.Round.Event} {expected : AgentLoop.Round.Command}
    {j j' : List Term} (h : (loop_private% advance) m event expected j = .ok (m', j')) :
    (AgentLoop.Round.step (roundOf m) event).2 = expected ∧
      roundOf m' = (AgentLoop.Round.step (roundOf m) event).1 := by
  obtain ⟨cmd, rfl⟩ := advance_ok h
  refine ⟨cmd, ?_⟩
  unfold roundOf
  rw [mkey_put_self, decode_encode]

syntax "round_one" : tactic
macro_rules
  | `(tactic| round_one) => `(tactic| (
    simp only [RoundFacts, result_eq, phase_eq, key_eq, stop_eq, notify_eq, cont_eq, commit_eq,
      materialize_eq, fetch_eq, setTimer_eq]
    intro m' effs same nr
    simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
    obtain ⟨same₁, same₂⟩ := same
    subst same₁ same₂
    unfold roundOf at nr ⊢
    try simp (config := { decide := true }) only [mkey_put_skip]
    exact nr))

syntax "round_close" : tactic
macro_rules
  | `(tactic| round_close) => `(tactic| ((repeat' split) <;> round_one))

theorem round_lift {machine x out : Term} (facts : RoundFacts x out)
    (same : roundOf x = roundOf machine) : RoundFacts machine out := by
  intro m' effs eq nr
  exact facts m' effs eq (same ▸ nr)

theorem round_of_put {machine v : Term} {k : String} (ne : k ≠ "rstate") :
    roundOf (machine.put (b k) v) = roundOf machine := by
  unfold roundOf
  rw [mkey_put_skip _ _ ne]

theorem guardOutcome_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% guardOutcome) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold guardOutcome
  dsplit
  all_goals round_close

theorem park_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% park) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold park
  dsplit
  all_goals round_close

theorem guardNotice_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% guardNotice) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold guardNotice
  dunfold_at "VerifiedKernel.Session.Loop.finalStop" h
  dsplit
  all_goals round_close

theorem noticeCleanup_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% noticeCleanup) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold noticeCleanup
  dsplit
  all_goals round_close

theorem finalize_round {ask : Loop.Ask} {state machine terminal out : Term} {j j' : List Term}
    (h : (loop_private% finalize) ask state machine terminal j = .ok (out, j')) : RoundFacts machine out := by
  dunfold finalize
  dsplit
  all_goals round_close

theorem toolTurn_round {machine outcome out : Term} {j j' : List Term}
    (h : (loop_private% toolTurn) machine outcome j = .ok (out, j')) : RoundFacts machine out := by
  dunfold toolTurn
  dsplit
  all_goals round_close

theorem finalRecord_round {ask : Loop.Ask} {state machine record out : Term} {j j' : List Term}
    (h : (loop_private% finalRecord) ask state machine record j = .ok (out, j')) : RoundFacts machine out := by
  dunfold finalRecord
  dsplit
  all_goals first
    | round_close
    | exact finalize_round h

theorem modelFailure_round {ask : Loop.Ask} {state machine info out : Term} {recover : Bool}
    {j j' : List Term}
    (h : (loop_private% modelFailure) ask state machine info recover j = .ok (out, j')) : RoundFacts machine out := by
  dunfold modelFailure
  dsplit
  all_goals round_close

theorem modelFailed_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% modelFailed) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold modelFailed
  dsplit
  all_goals round_close

theorem park_same {ask : Loop.Ask} {state machine m' eff : Term} {j j' : List Term}
    (h : (loop_private% park) ask state machine j = .ok (.tuple [m', eff], j')) : roundOf m' = roundOf machine := by
  dunfold park
  dsplit
  all_goals
    simp only [result_eq, phase_eq, Term.tuple.injEq, List.cons.injEq, and_true] at h
    obtain ⟨rfl, -⟩ := h
    exact round_of_put (by decide)

theorem round_of_same {machine m' : Term} {effs : List Term} (same : roundOf m' = roundOf machine) :
    RoundFacts machine (.tuple [m', list effs]) := by
  intro m'' effects eq nr
  simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at eq
  obtain ⟨rfl, -⟩ := eq
  exact same ▸ nr

theorem outputCommitted_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% outputCommitted) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold outputCommitted
  dsplit
  all_goals first
    | round_close
    | (simp only [result_eq]
       exact round_of_same (park_same ‹(loop_private% park) _ _ _ _ = _›))

theorem intentRecord_round {state machine record out : Term} {j j' : List Term}
    (h : (loop_private% intentRecord) state machine record j = .ok (out, j')) : RoundFacts machine out := by
  dunfold intentRecord
  dsplit
  all_goals first
    | exact toolTurn_round h
    | (obtain ⟨_, r1⟩ := roundOf_advance ‹(loop_private% advance) machine _ _ _ = _›
       obtain ⟨_, r2⟩ := roundOf_advance ‹(loop_private% advance) _ _ _ _ = _›
       simp only [result_eq]
       intro m' effs eq nr
       simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at eq
       obtain ⟨rfl, -⟩ := eq
       simp (config := { decide := true }) only [phase_eq, round_of_put]
       rw [r2, r1]
       exact step_not_ready _ (step_not_ready _ nr))
    | round_close

theorem toolsDone_round {ask : Loop.Ask} {state machine results async out : Term} {j j' : List Term}
    (h : (loop_private% toolsDone) ask state machine results async j = .ok (out, j')) : RoundFacts machine out := by
  dunfold toolsDone
  dsplit
  all_goals
    obtain ⟨_, r1⟩ := roundOf_advance ‹(loop_private% advance) machine _ _ _ = _›
    simp only [result_eq]
    intro m' effs eq nr
    simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at eq
    obtain ⟨rfl, -⟩ := eq
    try simp (config := { decide := true }) only [phase_eq, round_of_put]
    rw [r1]
    exact step_not_ready _ nr

theorem resultsStored_round {ask : Loop.Ask} {state machine events hwm base stored out : Term}
    {j j' : List Term}
    (h : (loop_private% resultsStored) ask state machine events hwm base stored j = .ok (out, j')) :
    RoundFacts machine out := by
  dunfold resultsStored
  dsplit
  all_goals round_close

theorem continuation_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% continuation) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold continuation
  dsplit
  all_goals
    obtain ⟨_, r1⟩ := roundOf_advance ‹(loop_private% advance) machine _ _ _ = _›
  all_goals first
    | (simp only [result_eq]
       intro m' effs eq nr
       simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at eq
       obtain ⟨rfl, -⟩ := eq
       first
         | (rw [park_same ‹(loop_private% park) _ _ _ _ = _›, r1]; exact step_not_ready _ nr)
         | (simp (config := { decide := true }) only [phase_eq, round_of_put]
            rw [r1]
            exact step_not_ready _ nr))

theorem expire_round {state machine busy out : Term} {j j' : List Term}
    (h : (loop_private% expire) state machine busy j = .ok (out, j')) : RoundFacts machine out := by
  dunfold expire
  dsplit
  all_goals try round_close
  all_goals dsplit_decide
  all_goals dsplit
  all_goals round_close

theorem expireEntry_round {state machine out : Term} {j j' : List Term}
    (h : (loop_private% expireEntry) state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold expireEntry
  dsplit
  all_goals first
    | round_close
    | exact round_lift (expire_round h) (round_of_put (by decide))

theorem activation_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% activation) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold activation
  dsplit
  all_goals first
    | round_close
    | exact round_lift (expireEntry_round h) (round_of_put (by decide))

theorem timeoutEntry_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% timeoutEntry) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold timeoutEntry
  dsplit
  all_goals first
    | round_close
    | exact round_lift (expireEntry_round h) (round_of_put (by decide))

theorem classify_round {ask : Loop.Ask} {state machine out : Term} {j j' : List Term}
    (h : (loop_private% classify) ask state machine j = .ok (out, j')) : RoundFacts machine out := by
  dunfold classify
  obtain ⟨_, _, _, _, _, hp⟩ := parts_cases ((loop_private% key) machine "response")
  rw [hp] at h
  dsimp only at h
  dsplit
  all_goals try (generalize hc : AgentLoop.TurnOutcome.classify _ = c at h; dsplit)
  all_goals first
    | exact round_lift (modelFailure_round h) (by simp (config := { decide := true }) only [round_of_put])
    | exact round_lift (finalize_round h) (by simp (config := { decide := true }) only [round_of_put])
    | exact round_lift (toolTurn_round h) (by simp (config := { decide := true }) only [round_of_put])
    | exact round_lift (modelFailure_round ‹_›) (by simp (config := { decide := true }) only [round_of_put])
    | exact round_lift (finalize_round ‹_›) (by simp (config := { decide := true }) only [round_of_put])
    | exact round_lift (toolTurn_round ‹_›) (by simp (config := { decide := true }) only [round_of_put])

/-- The events that the host answers with. Entry events start a new machine. -/
def Answer (event : Term) : Prop :=
  event = a "continue" ∨ (∃ record, event = .tuple [a "record", record]) ∨
    (∃ results async, event = .tuple [a "tools_done", results, async]) ∨
    (∃ events hwm base stored, event = .tuple [a "results_stored", events, hwm, base, stored]) ∨
    ∃ value, event = .tuple [a "fact", value]

/-- A step on an answer event keeps a machine that has left `ready` out of `ready`. -/
theorem step_round {ask : Loop.Ask} {state machine event out : Term} {j j' : List Term}
    (answer : Answer event)
    (h : Loop.stepWith ask state (.tuple [machine, event]) j = .ok (out, j')) : RoundFacts machine out := by
  unfold Loop.stepWith at h
  dunfold_at "VerifiedKernel.Session.Loop.finalStop" h
  dsplit
  all_goals try (simp only [ite_ok_iff] at h)
  all_goals repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := h)
  all_goals try dsplit
  all_goals first
    | (exfalso; rcases answer with h' | ⟨_, h'⟩ | ⟨_, _, h'⟩ | ⟨_, _, _, _, h'⟩ | ⟨_, h'⟩ <;> simp at h'; done)
    | round_close
    | exact round_lift (guardNotice_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (modelFailure_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (finalRecord_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (intentRecord_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (toolsDone_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (resultsStored_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (activation_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (timeoutEntry_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (expire_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (classify_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (outputCommitted_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (modelFailed_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (noticeCleanup_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (guardOutcome_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (continuation_round h) (by simp (config := { decide := true }) only [phase_eq, round_of_put])
    | exact round_lift (guardNotice_round h) rfl
    | exact round_lift (modelFailure_round h) rfl
    | exact round_lift (finalRecord_round h) rfl
    | exact round_lift (intentRecord_round h) rfl
    | exact round_lift (toolsDone_round h) rfl
    | exact round_lift (resultsStored_round h) rfl
    | exact round_lift (activation_round h) rfl
    | exact round_lift (timeoutEntry_round h) rfl
    | exact round_lift (expire_round h) rfl
    | exact round_lift (classify_round h) rfl
    | exact round_lift (outputCommitted_round h) rfl
    | exact round_lift (modelFailed_round h) rfl
    | exact round_lift (noticeCleanup_round h) rfl
    | exact round_lift (guardOutcome_round h) rfl
    | exact round_lift (continuation_round h) rfl

theorem toolTurn_no_commit {machine outcome out m' opts mode : Term} {effs events : List Term}
    {j j' : List Term} (h : (loop_private% toolTurn) machine outcome j = .ok (out, j'))
    (same : out = .tuple [m', list effs]) (mem : commitEffect events opts mode ∈ effs) : False := by
  dunfold toolTurn
  dsplit
  simp only [result_eq, notify_eq, Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
  obtain ⟨-, rfl⟩ := same
  simp [commitEffect] at mem

theorem intentRecord_commit_round {state machine record out m' opts mode : Term} {effs events : List Term}
    {j j' : List Term} (h : (loop_private% intentRecord) state machine record j = .ok (out, j'))
    (same : out = .tuple [m', list effs]) (mem : commitEffect events opts mode ∈ effs) :
    roundOf m' = .awaitTools := by
  dunfold intentRecord
  dsplit
  all_goals first
    | exact (toolTurn_no_commit h same mem).elim
    | (obtain ⟨c1, r1⟩ := roundOf_advance ‹(loop_private% advance) machine _ _ _ = _›
       obtain ⟨c2, r2⟩ := roundOf_advance ‹(loop_private% advance) _ _ _ _ = _›
       simp only [result_eq, Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true] at same
       obtain ⟨rfl, -⟩ := same
       simp (config := { decide := true }) only [phase_eq, round_of_put]
       rw [r2]
       have := (AgentLoop.Round.execute_requires_committed _ _ c2).1
       rw [this]
       rfl)

theorem start_requires_ready {s : AgentLoop.Round.State}
    (h : (AgentLoop.Round.step s .start).2 = .commitIntent) : s = .ready := by
  cases s <;> simp_all [AgentLoop.Round.step]

/-- A step with an intent commit starts at round state `ready` and leaves it. -/
theorem step_intent_round {s m ev m' opts mode : Term} {effs events : List Term}
    (step : StepOK Loop.queryAsk s m ev m' effs) (mem : commitEffect events opts mode ∈ effs)
    (map : mode.isMap = true) : roundOf m = .ready ∧ roundOf m' = .awaitTools := by
  cases step_commit_source step mem with
  | intent record nmid entry phase nextId fresh checked roundStart roundCommitted =>
    refine ⟨start_requires_ready roundStart, ?_⟩
    · obtain ⟨j, j', h⟩ := step
      subst entry
      generalize hv : Term.tuple [a "record", record] = event at h
      unfold Loop.stepWith at h
      dsplit
      all_goals try (exfalso; simp [a] at hv; done)
      all_goals first
        | (simp only [a, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at hv
           subst hv
           exact intentRecord_commit_round h rfl mem)
        | (exfalso
           have other := WorkConservation.binary_beq_true ‹(_ == b "final_record") = true›
           exact binary_ne (by decide) (phase.symm.trans other))
  | _ => simp [nil, Term.isMap] at map

/-! ## Rounds in the host log -/

/-- Position `k` is a durable intent commit. -/
def IntentCommitAt (log : List HostLabel) (k : Nat) : Prop :=
  ∃ events mode, log[k]? = some (.commit events mode) ∧ mode.isMap = true

/-- Position `q` starts a round. -/
def EnterAt (log : List HostLabel) (q : Nat) : Prop := ∃ event, log[q]? = some (.enter event)

/-- Two durable intent commits have a round entry between them. -/
def IntentOnce (log : List HostLabel) : Prop :=
  ∀ k₁ k₂, k₁ < k₂ → IntentCommitAt log k₁ → IntentCommitAt log k₂ → ∃ q, k₁ < q ∧ q < k₂ ∧ EnterAt log q

/-- The current round has a durable intent commit. -/
def RoundOpen (log : List HostLabel) : Prop :=
  ∃ k, IntentCommitAt log k ∧ ∀ q, k < q → q < log.length → ¬EnterAt log q

/-- In an open round the live machine has left `ready`, and the host answers it. -/
def RoundControl : Control → Prop
  | .idle => True
  | .feed machine event => roundOf machine ≠ .ready ∧ Answer event
  | .perform machine _ => roundOf machine ≠ .ready
  | .running machine _ => roundOf machine ≠ .ready

structure RoundInv (log : List HostLabel) (σ : HostState) : Prop where
  once : IntentOnce log
  control : RoundOpen log → RoundControl σ.control

theorem intentCommitAt_split {log extra : List HostLabel} {k : Nat} (h : IntentCommitAt (log ++ extra) k) :
    (k < log.length ∧ IntentCommitAt log k) ∨ (log.length ≤ k ∧ IntentCommitAt extra (k - log.length)) := by
  obtain ⟨events, mode, at_, map⟩ := h
  by_cases small : k < log.length
  · rw [List.getElem?_append_left small] at at_
    exact Or.inl ⟨small, events, mode, at_, map⟩
  · rw [List.getElem?_append_right (Nat.le_of_not_lt small)] at at_
    exact Or.inr ⟨Nat.le_of_not_lt small, events, mode, at_, map⟩

theorem enterAt_old {log extra : List HostLabel} {q : Nat} (h : EnterAt log q) : EnterAt (log ++ extra) q := by
  obtain ⟨event, at_⟩ := h
  exact ⟨event, getElem?_old at_⟩

/-- Labels without an intent commit or a round entry. -/
def Plain (labels : List HostLabel) : Prop :=
  (∀ k, ¬IntentCommitAt labels k) ∧ ∀ q, ¬EnterAt labels q

theorem plain_cons {x : HostLabel} {rest : List HostLabel}
    (commit : ∀ events mode, x = .commit events mode → mode.isMap = false)
    (enter : ∀ event, x ≠ .enter event) (tail : Plain rest) : Plain (x :: rest) := by
  refine ⟨fun k ⟨events, mode, at_, map⟩ => ?_, fun q ⟨event, at_⟩ => ?_⟩
  · cases k with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at at_
      rw [commit events mode at_] at map
      cases map
    | succ k => exact tail.1 k ⟨events, mode, at_, map⟩
  · cases q with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at at_
      exact enter event at_
    | succ q => exact tail.2 q ⟨event, at_⟩

theorem plain_nil : Plain [] := ⟨fun k ⟨_, _, h, _⟩ => by simp at h, fun q ⟨_, h⟩ => by simp at h⟩

syntax "plain_labels" : tactic
macro_rules
  | `(tactic| plain_labels) => `(tactic|
    (repeat' first
      | exact plain_nil
      | (refine plain_cons (fun _ _ bad => by cases bad) (fun _ bad => by cases bad) ?_)))

theorem plain_commit {e : List Term} {mode : Term} (map : mode.isMap = false) :
    Plain [HostLabel.commit e mode] :=
  plain_cons (fun _ _ same => by cases same; exact map) (fun _ bad => by cases bad) plain_nil

theorem once_plain {log extra : List HostLabel} (once : IntentOnce log) (plain : Plain extra) :
    IntentOnce (log ++ extra) := by
  intro k₁ k₂ lt c₁ c₂
  rcases intentCommitAt_split c₂ with ⟨s₂, o₂⟩ | ⟨_, n₂⟩
  · rcases intentCommitAt_split c₁ with ⟨s₁, o₁⟩ | ⟨_, _⟩
    · obtain ⟨q, lo, hi, e⟩ := once k₁ k₂ lt o₁ o₂
      exact ⟨q, lo, hi, enterAt_old e⟩
    · omega
  · exact (plain.1 _ n₂).elim

theorem open_plain {log extra : List HostLabel} (plain : Plain extra) (h : RoundOpen (log ++ extra)) :
    RoundOpen log := by
  obtain ⟨k, c, quiet⟩ := h
  rcases intentCommitAt_split c with ⟨s, o⟩ | ⟨_, n⟩
  · refine ⟨k, o, fun q lo hi e => quiet q lo (by simp; omega) (enterAt_old e)⟩
  · exact (plain.1 _ n).elim

theorem roundInv_plain {log extra : List HostLabel} {σ σ' : HostState} (inv : RoundInv log σ)
    (plain : Plain extra) (control : RoundOpen log → RoundControl σ'.control) : RoundInv (log ++ extra) σ' :=
  ⟨once_plain inv.once plain, fun h => control (open_plain plain h)⟩

/-- A step with a new intent commit label: the round was not open before, so
every earlier intent commit has an entry after it. -/
theorem once_new_commit {log : List HostLabel} {pre post : List HostLabel} {events : List Term} {mode : Term}
    (once : IntentOnce log) (closed : ¬RoundOpen log) (hpre : Plain pre) (hpost : Plain post) :
    IntentOnce (log ++ (pre ++ HostLabel.commit events mode :: post)) := by
  intro k₁ k₂ lt c₁ c₂
  have old : ∀ k, IntentCommitAt (log ++ (pre ++ HostLabel.commit events mode :: post)) k →
      (k < log.length ∧ IntentCommitAt log k) ∨ k = log.length + pre.length := by
    intro k c
    rcases intentCommitAt_split c with ⟨s, o⟩ | ⟨ge, n⟩
    · exact Or.inl ⟨s, o⟩
    · right
      obtain ⟨e, md, at_, map⟩ := n
      by_cases inPre : k - log.length < pre.length
      · rw [List.getElem?_append_left inPre] at at_
        exact (hpre.1 _ ⟨e, md, at_, map⟩).elim
      · rw [List.getElem?_append_right (Nat.le_of_not_lt inPre)] at at_
        cases hx : k - log.length - pre.length with
        | zero => omega
        | succ x =>
          rw [hx] at at_
          simp only [List.getElem?_cons_succ] at at_
          exact (hpost.1 _ ⟨e, md, at_, map⟩).elim
  rcases old k₂ c₂ with ⟨s₂, o₂⟩ | e₂
  · rcases old k₁ c₁ with ⟨_, o₁⟩ | _
    · obtain ⟨q, lo, hi, e⟩ := once k₁ k₂ lt o₁ o₂
      exact ⟨q, lo, hi, enterAt_old e⟩
    · omega
  · rcases old k₁ c₁ with ⟨s₁, o₁⟩ | e₁
    · have : ¬∀ q, k₁ < q → q < log.length → ¬EnterAt log q := fun quiet => closed ⟨k₁, o₁, quiet⟩
      obtain ⟨q, lo, hi, e⟩ : ∃ q, k₁ < q ∧ q < log.length ∧ EnterAt log q :=
        Classical.byContradiction fun none => this (fun q lo hi e => none ⟨q, lo, hi, e⟩)
      exact ⟨q, lo, by omega, enterAt_old e⟩
    · omega

theorem once_enter {log : List HostLabel} {event : Term} (once : IntentOnce log) :
    IntentOnce (log ++ [HostLabel.enter event]) := by
  intro k₁ k₂ lt c₁ c₂
  rcases intentCommitAt_split c₂ with ⟨s₂, o₂⟩ | ⟨_, n₂⟩
  · rcases intentCommitAt_split c₁ with ⟨_, o₁⟩ | ⟨_, _⟩
    · obtain ⟨q, lo, hi, e⟩ := once k₁ k₂ lt o₁ o₂
      exact ⟨q, lo, hi, enterAt_old e⟩
    · omega
  · obtain ⟨e, md, at_, _⟩ := n₂
    cases hk : k₂ - log.length with
    | zero => rw [hk] at at_; simp at at_
    | succ x => rw [hk] at at_; simp at at_

theorem closed_enter {log : List HostLabel} {event : Term} : ¬RoundOpen (log ++ [HostLabel.enter event]) := by
  rintro ⟨k, c, quiet⟩
  rcases intentCommitAt_split c with ⟨s, _⟩ | ⟨_, n⟩
  · exact quiet log.length s (by simp) ⟨event, by simp⟩
  · obtain ⟨e, md, at_, _⟩ := n
    cases hk : k - log.length with
    | zero => rw [hk] at at_; simp at at_
    | succ x => rw [hk] at at_; simp at at_

theorem specMode_map {mode : Term} (h : specMode mode = true) : mode.isMap = true := by
  simp only [specMode, Bool.and_eq_true] at h
  exact h.1

/-- The step before a new intent commit: the round is not open, and the new
machine has left `ready`. -/
theorem intent_step_closed {log : List HostLabel} {σ : HostState} {s m ev m' opts mode : Term}
    {effs events : List Term} (inv : RoundInv log σ) (feed : σ.control = .feed m ev)
    (step : StepOK Loop.queryAsk s m ev m' effs) (mem : commitEffect events opts mode ∈ effs)
    (map : mode.isMap = true) : ¬RoundOpen log ∧ roundOf m' ≠ .ready := by
  obtain ⟨ready, tools⟩ := step_intent_round step mem map
  refine ⟨fun h => ?_, by rw [tools]; simp⟩
  have ctl := inv.control h
  rw [feed] at ctl
  exact ctl.1 ready

theorem answer_step {s m ev m' : Term} {effs : List Term} (step : StepOK Loop.queryAsk s m ev m' effs)
    (answer : Answer ev) (away : roundOf m ≠ .ready) : roundOf m' ≠ .ready := by
  obtain ⟨j, j', h⟩ := step
  exact step_round answer h m' effs rfl away

/-- One host transition keeps the round invariant. -/
theorem roundInv_step {cfg : HostConfig} {log labels : List HostLabel} {σ σ' : HostState}
    (inv : RoundInv log σ) (next : HostStep cfg σ labels σ') : RoundInv (log ++ labels) σ' := by
  have ctl := inv.control
  cases next with
  | enter idle => exact ⟨once_enter inv.once, fun h => (closed_enter h).elim⟩
  | request idle model granted => exact ⟨once_enter inv.once, fun h => (closed_enter h).elim⟩
  | «local» feed step noCommit =>
    refine roundInv_plain inv plain_nil fun h => ?_
    have c := ctl h
    rw [feed] at c
    exact answer_step step c.2 c.1
  | @commit machine event machine' t mode opts pre events post feed clean first step land =>
    cases map : mode.isMap
    · refine roundInv_plain inv (plain_commit map) fun h => ?_
      have c := ctl h
      rw [feed] at c
      exact answer_step step c.2 c.1
    · obtain ⟨closed, away⟩ := intent_step_closed inv feed step mem_of_commit_split map
      exact ⟨by simpa using once_new_commit (pre := []) (post := []) inv.once closed plain_nil plain_nil,
        fun _ => away⟩
  | reroute feed clean first step noCommit =>
    refine roundInv_plain inv plain_nil fun h => ?_
    have c := ctl h
    rw [feed] at c
    exact answer_step step c.2 c.1
  | @fenceCommit machine event machine' t mode opts pre events post feed dirty step notSpeculative land cas =>
    cases map : mode.isMap
    · refine roundInv_plain inv (plain_commit map) fun h => ?_
      have c := ctl h
      rw [feed] at c
      exact answer_step step c.2 c.1
    · obtain ⟨closed, away⟩ := intent_step_closed inv feed step mem_of_commit_split map
      exact ⟨by simpa using once_new_commit (pre := []) (post := []) inv.once closed plain_nil plain_nil,
        fun _ => away⟩
  | @speculative machine event machine' t mode opts calls flags results async pre events mid
      feed step isSpeculative land executed cas =>
    obtain ⟨closed, away⟩ := intent_step_closed inv feed step mem_of_commit_split (specMode_map isSpeculative)
    refine ⟨?_, fun _ => ⟨away, Or.inr (Or.inr (Or.inl ⟨_, _, rfl⟩))⟩⟩
    have := once_new_commit (events := events) (mode := mode)
      (pre := [.written events, .dispatch (mkey flags "aid") σ.calls (mkey flags "mode") true])
      (post := [.toolsReturned results]) inv.once closed (by plain_labels) (by plain_labels)
    simpa using this
  | speculativeFailed feed step isSpeculative land =>
    exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | skip perform kind =>
    refine roundInv_plain inv plain_nil fun h => ?_
    have c := ctl h
    rw [perform] at c
    exact c
  | write perform land =>
    refine roundInv_plain inv (by plain_labels) fun h => ?_
    have c := ctl h
    rw [perform] at c
    exact c
  | reply perform answer =>
    refine roundInv_plain inv plain_nil fun h => ?_
    have c := ctl h
    rw [perform] at c
    refine ⟨c, ?_⟩
    cases answer
    · exact Or.inl rfl
    · exact Or.inr (Or.inr (Or.inr (Or.inl ⟨_, _, _, _, rfl⟩)))
    · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨_, rfl⟩)))
  | record perform built =>
    refine roundInv_plain inv (by plain_labels) fun h => ?_
    have c := ctl h
    rw [perform] at c
    exact ⟨c, Or.inr (Or.inl ⟨_, rfl⟩)⟩
  | dispatch perform =>
    refine roundInv_plain inv (by plain_labels) fun h => ?_
    have c := ctl h
    rw [perform] at c
    exact c
  | returned running executed =>
    refine roundInv_plain inv (by plain_labels) fun h => ?_
    have c := ctl h
    rw [running] at c
    exact ⟨c, Or.inr (Or.inr (Or.inl ⟨_, _, rfl⟩))⟩
  | planned perform =>
    refine roundInv_plain inv (by plain_labels) fun h => ?_
    have c := ctl h
    rw [perform] at c
    exact ⟨c, Or.inl rfl⟩
  | materialize perform plan land => exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | materializeRun perform plan land => exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | fast idle plan land =>
    exact roundInv_plain inv (by plain_labels) fun _ => by show RoundControl σ.control; rw [idle]; trivial
  | stop perform => exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | fence idle dirty cas =>
    exact roundInv_plain inv (by plain_labels) fun _ => by rw [idle]; trivial
  | refresh clean => exact roundInv_plain inv plain_nil fun h => ctl h
  | env plan land => exact roundInv_plain inv (by plain_labels) fun h => ctl h
  | abort busy => exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | crash => exact roundInv_plain inv (by plain_labels) fun _ => trivial
  | restart idle clean plan land =>
    exact roundInv_plain inv (by plain_labels) fun _ => by show RoundControl σ.control; rw [idle]; trivial

theorem roundInv_run {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) : RoundInv log σ := by
  induction run with
  | refl =>
    refine ⟨fun k₁ k₂ _ c _ => ?_, fun _ => by rw [init.1]; trivial⟩
    obtain ⟨_, _, h, _⟩ := c
    simp at h
  | step _ next ih => exact roundInv_step ih next

/-! ## The proven round machine on the host log -/

/-- One label on the round state: an entry starts a new round at `ready`, and
another label feeds its acknowledgement events to `AgentLoop.Round.step`. -/
def roundLabel (s : AgentLoop.Round.State) (label : HostLabel) : AgentLoop.Round.State :=
  match label with
  | .enter _ => .ready
  | _ => (AgentLoop.Round.trace s (roundEvent label)).1

/-- The round state after a log. -/
def roundState (log : List HostLabel) : AgentLoop.Round.State := log.foldl roundLabel .ready

theorem roundLabel_other {s : AgentLoop.Round.State} {label : HostLabel} (other : ∀ event, label ≠ .enter event) :
    roundLabel s label = (AgentLoop.Round.trace s (roundEvent label)).1 := by
  cases label <;> first | rfl | exact absurd rfl (other _)

theorem roundState_snoc (log : List HostLabel) (label : HostLabel) :
    roundState (log ++ [label]) = roundLabel (roundState log) label := by
  simp [roundState]

theorem roundState_take_succ {log : List HostLabel} {n : Nat} {label : HostLabel} (h : log[n]? = some label) :
    roundState (log.take (n + 1)) = roundLabel (roundState (log.take n)) label := by
  rw [List.take_add_one, h]
  exact roundState_snoc _ _

theorem roundState_take_none {log : List HostLabel} {n : Nat} (h : log[n]? = none) :
    roundState (log.take (n + 1)) = roundState (log.take n) := by
  rw [List.take_add_one, h]
  simp

/-- From `ready`, only a durable intent commit leaves `ready`. -/
theorem roundLabel_ready {label : HostLabel}
    (notIntent : ∀ events mode, label = .commit events mode → mode.isMap = false) :
    roundLabel .ready label = .ready := by
  cases label with
  | enter => rfl
  | commit events mode =>
    have map := notIntent events mode rfl
    simp [roundLabel, roundEvent, map, AgentLoop.Round.trace, AgentLoop.runTrace, AgentLoop.Round.transition,
      AgentLoop.Round.step]
  | _ => simp [roundLabel, roundEvent, AgentLoop.Round.trace, AgentLoop.runTrace, AgentLoop.Round.transition,
      AgentLoop.Round.step]

/-- A round state away from `ready` comes from an intent commit of the current round. -/
theorem roundState_away {log : List HostLabel} :
    ∀ n, roundState (log.take n) ≠ .ready →
      ∃ k < n, IntentCommitAt log k ∧ ∀ q, k < q → q < n → ¬EnterAt log q := by
  intro n
  induction n with
  | zero => intro h; exact (h rfl).elim
  | succ n ih =>
    intro away
    cases hl : log[n]? with
    | none =>
      rw [roundState_take_none hl] at away
      obtain ⟨k, lt, c, quiet⟩ := ih away
      refine ⟨k, by omega, c, fun q lo hi e => ?_⟩
      by_cases qn : q < n
      · exact quiet q lo qn e
      · obtain ⟨event, at_⟩ := e
        have : q = n := by omega
        subst this
        rw [hl] at at_
        cases at_
    | some label =>
      rw [roundState_take_succ hl] at away
      by_cases enter : ∃ event, label = .enter event
      · obtain ⟨event, rfl⟩ := enter
        exact (away rfl).elim
      have notEnter : ∀ event, label ≠ .enter event := fun event same => enter ⟨event, same⟩
      by_cases intent : ∃ events mode, label = .commit events mode ∧ mode.isMap = true
      · obtain ⟨events, mode, rfl, map⟩ := intent
        exact ⟨n, by omega, ⟨events, mode, hl, map⟩, fun q lo hi => by omega⟩
      have plainLabel : ∀ events mode, label = .commit events mode → mode.isMap = false := by
        intro events mode same
        cases h : mode.isMap
        · rfl
        · exact (intent ⟨events, mode, same, h⟩).elim
      by_cases ready : roundState (log.take n) = .ready
      · rw [ready, roundLabel_ready plainLabel] at away
        exact (away rfl).elim
      obtain ⟨k, lt, c, quiet⟩ := ih ready
      refine ⟨k, by omega, c, fun q lo hi e => ?_⟩
      by_cases qn : q < n
      · exact quiet q lo qn e
      · obtain ⟨event, at_⟩ := e
        have : q = n := by omega
        subst this
        rw [hl] at at_
        exact notEnter event (Option.some.inj at_)

/-- A round is at `ready` when its durable intent commit arrives. -/
theorem roundState_at_intent {log : List HostLabel} {k : Nat} (once : IntentOnce log)
    (c : IntentCommitAt log k) : roundState (log.take k) = .ready := by
  refine Classical.byContradiction fun away => ?_
  obtain ⟨k₁, lt, c₁, quiet⟩ := roundState_away k away
  obtain ⟨q, lo, hi, e⟩ := once k₁ k lt c₁ c
  exact quiet q lo hi e

theorem trace_intent {events : List Term} {mode : Term} (map : mode.isMap = true) :
    AgentLoop.Round.trace .ready (roundEvent (.commit events mode)) =
      (.awaitTools, [.commitIntent, .executeTools]) := by
  simp [roundEvent, map, AgentLoop.Round.trace, AgentLoop.runTrace, AgentLoop.Round.transition, AgentLoop.Round.step]

theorem roundLabel_quiet {s : AgentLoop.Round.State} {label : HostLabel} (quiet : Quiet label) :
    roundLabel s label = s := by
  rw [roundLabel_other quiet.2.1, quiet.1]
  rfl

theorem roundState_gap {log : List HostLabel} {k : Nat} :
    ∀ d, QuietGap log k (k + 1 + d) → roundState (log.take (k + 1 + d)) = roundState (log.take (k + 1)) := by
  intro d
  induction d with
  | zero => intro _; rfl
  | succ d ih =>
    intro gap
    have inner : QuietGap log k (k + 1 + d) := fun q lo hi => gap q lo (by omega)
    obtain ⟨label, at_, quiet⟩ := gap (k + 1 + d) (by omega) (by omega)
    rw [show k + 1 + (d + 1) = k + 1 + d + 1 by omega, roundState_take_succ at_, roundLabel_quiet quiet]
    exact ih inner

/-! ## Round refinement -/

/-- Two durable intent commits lie in different rounds: an `enter` label is
between them. -/
theorem intent_once_per_round {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {k₁ k₂ : Nat} (lt : k₁ < k₂)
    (first : IntentCommitAt log k₁) (second : IntentCommitAt log k₂) :
    ∃ q, k₁ < q ∧ q < k₂ ∧ EnterAt log q :=
  (roundInv_run run init).once k₁ k₂ lt first second

/-- `round_refines`: feed the proven `AgentLoop.Round` machine with the
acknowledgement events of the host log (`roundEvent`), and reset it at each
round entry. Before a non-speculative model-turn dispatch, the round has a
durable intent commit. At that commit the machine is at `ready` and issues
`commitIntent` and `executeTools`. Between the commit and the dispatch no label
starts a round or feeds an event, so the machine still waits in `awaitTools`
when the host dispatches. The dispatch is the `executeTools` command of the
round, after the durable acknowledgement that `commit_history_precedes_commands`
requires. `intent_once_per_round` and `dispatch_once_per_round` give the
bound of `commands_at_most_once` for real rounds. -/
theorem round_refines {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {i : Nat} {aid calls : Term}
    (at_ : log[i]? = some (.dispatch aid calls (b "model_turn") false)) :
    ∃ k < i, ∃ label, log[k]? = some label ∧ roundState (log.take k) = .ready ∧
      AgentLoop.Round.trace .ready (roundEvent label) = (.awaitTools, [.commitIntent, .executeTools]) ∧
      (∀ q, k < q → q < i → ¬EnterAt log q) ∧ roundState (log.take i) = .awaitTools := by
  obtain ⟨k, lt, spec, record, w, commit, _, _, _, _, _, gap⟩ := (intentInv_run run init).durable i aid calls at_
  have map : (intentMode record).isMap = true := rfl
  have intent : IntentCommitAt log k := ⟨_, _, commit, map⟩
  have ready := roundState_at_intent (roundInv_run run init).once intent
  refine ⟨k, lt, _, commit, ready, trace_intent map, fun q lo hi e => ?_, ?_⟩
  · obtain ⟨label, at', quiet⟩ := gap q lo hi
    obtain ⟨event, at''⟩ := e
    rw [at'] at at''
    exact quiet.2.1 event (Option.some.inj at'')
  · obtain ⟨d, rfl⟩ : ∃ d, i = k + 1 + d := ⟨i - (k + 1), by omega⟩
    rw [roundState_gap d gap, roundState_take_succ commit, ready, roundLabel_other (fun _ bad => by cases bad),
      trace_intent map]

/-- Two non-speculative model-turn dispatches lie in different rounds. -/
theorem dispatch_once_per_round {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {i₁ i₂ : Nat} {aid₁ aid₂ calls₁ calls₂ : Term}
    (lt : i₁ < i₂)
    (first : log[i₁]? = some (.dispatch aid₁ calls₁ (b "model_turn") false))
    (second : log[i₂]? = some (.dispatch aid₂ calls₂ (b "model_turn") false)) :
    ∃ q, i₁ < q ∧ q < i₂ ∧ EnterAt log q := by
  have inv := intentInv_run run init
  obtain ⟨k₁, l₁, _, r₁, _, c₁, _, _, _, _, _, g₁⟩ := inv.durable i₁ aid₁ calls₁ first
  obtain ⟨k₂, l₂, _, r₂, _, c₂, _, _, _, _, _, g₂⟩ := inv.durable i₂ aid₂ calls₂ second
  have before : i₁ < k₂ := by
    refine Classical.byContradiction fun ge => ?_
    by_cases same : i₁ = k₂
    · subst same
      rw [first] at c₂
      cases c₂
    · obtain ⟨label, at_, quiet⟩ := g₂ i₁ (by omega) lt
      rw [first] at at_
      exact quiet.2.2 _ _ _ _ (Option.some.inj at_).symm
  obtain ⟨q, lo, hi, e⟩ := intent_once_per_round run init (by omega) ⟨_, _, c₁, rfl⟩ ⟨_, _, c₂, rfl⟩
  refine ⟨q, ?_, by omega, e⟩
  refine Classical.byContradiction fun le => ?_
  by_cases same : q = i₁
  · subst same
    obtain ⟨event, at_⟩ := e
    rw [first] at at_
    cases at_
  · obtain ⟨label, at_, quiet⟩ := g₁ q lo (by omega)
    obtain ⟨event, at'⟩ := e
    rw [at_] at at'
    exact quiet.2.1 event (Option.some.inj at')

/-! ## The runtime failure notice -/

/-- A durable commit before position `i` holds the notice assistant event at
`aid` with the single call `call`. -/
def NoticeBefore (log : List HostLabel) (i : Nat) (aid call : Term) : Prop :=
  ∃ k < i, ∃ events sid, log[k]? = some (.commit events nil) ∧ noticeAssistant sid aid call ∈ events

/-- A machine in phase `notice_cleanup` holds a notice that a durable commit recorded. -/
def MachineNoticed (log : List HostLabel) (machine : Term) : Prop :=
  phaseIs machine "notice_cleanup" →
    NoticeBefore log log.length (mkey machine "notice_aid") (mkey machine "notice")

/-- The mode facts of a pending dispatch. -/
def ModeRecorded (log : List HostLabel) (i : Nat) (aid calls mode : Term) : Prop :=
  mode = b "model_turn" ∨
    (mode = b "runtime_failure_notice" ∧ ∃ call, calls = list [call] ∧ NoticeBefore log i aid call)

def NoticeControl (log : List HostLabel) : Control → Prop
  | .idle => True
  | .feed machine _ => MachineNoticed log machine
  | .perform machine effects => MachineNoticed log machine ∧
      ∀ calls flags, runToolsEffect calls flags ∈ effects →
        ModeRecorded log log.length (mkey flags "aid") calls (mkey flags "mode")
  | .running machine _ => MachineNoticed log machine

/-- The invariant of `notice_after_durable_record`. -/
structure NoticeInv (log : List HostLabel) (σ : HostState) : Prop where
  dispatched : ∀ i aid calls mode, log[i]? = some (.dispatch aid calls mode false) →
    ModeRecorded log i aid calls mode
  control : NoticeControl log σ.control

theorem noticeBefore_mono {log extra : List HostLabel} {i i' : Nat} {aid call : Term}
    (h : NoticeBefore log i aid call) (le : i ≤ i') : NoticeBefore (log ++ extra) i' aid call := by
  obtain ⟨k, lt, events, sid, at_, mem⟩ := h
  exact ⟨k, by omega, events, sid, getElem?_old at_, mem⟩

theorem modeRecorded_mono {log extra : List HostLabel} {i i' : Nat} {aid calls mode : Term}
    (h : ModeRecorded log i aid calls mode) (le : i ≤ i') : ModeRecorded (log ++ extra) i' aid calls mode := by
  rcases h with model | ⟨notice, call, eq, before⟩
  · exact Or.inl model
  · exact Or.inr ⟨notice, call, eq, noticeBefore_mono before le⟩

theorem noticed_mono {log extra : List HostLabel} {m : Term} (h : MachineNoticed log m) :
    MachineNoticed (log ++ extra) m :=
  fun hp => noticeBefore_mono (h hp) (by simp)

theorem noticeControl_mono {log extra : List HostLabel} {c : Control} (h : NoticeControl log c) :
    NoticeControl (log ++ extra) c := by
  cases c with
  | idle => trivial
  | feed m ev => exact noticed_mono h
  | perform m effs =>
    exact ⟨noticed_mono h.1, fun calls flags mem => modeRecorded_mono (h.2 calls flags mem) (by simp)⟩
  | running m calls => exact noticed_mono h

theorem noticeInv_mono {log extra : List HostLabel} {σ σ' : HostState} (inv : NoticeInv log σ)
    (none : NoDispatch extra) (control : NoticeControl (log ++ extra) σ'.control) :
    NoticeInv (log ++ extra) σ' := by
  refine ⟨fun i aid calls mode at_ => ?_, control⟩
  obtain ⟨small, _⟩ := dispatchAt_none none ⟨calls, mode, false, at_⟩
  rw [List.getElem?_append_left small] at at_
  exact modeRecorded_mono (inv.dispatched i aid calls mode at_) (Nat.le_refl _)

/-- The notice facts of one kernel step. `labelled` says that a notice commit
of the step has a commit label in the new log. -/
theorem noticed_step (sources : StepSources) {log extra : List HostLabel} {s m ev m' : Term}
    {effs : List Term} (noticed : MachineNoticed log m) (step : StepOK Loop.queryAsk s m ev m' effs)
    (labelled : ∀ events opts, commitEffect events opts nil ∈ effs →
      ∃ k < (log ++ extra).length, (log ++ extra)[k]? = some (.commit events nil)) :
    MachineNoticed (log ++ extra) m' ∧ ∀ calls flags, runToolsEffect calls flags ∈ effs →
      ModeRecorded (log ++ extra) (log ++ extra).length (mkey flags "aid") calls (mkey flags "mode") := by
  have facts := stepOK_facts step m' effs rfl
  refine ⟨fun hp => ?_, fun calls flags mem => ?_⟩
  · rcases (facts.1 hp).1 with ⟨events, aid, sid, call, noticeIn, _, aidIs, assistant, callIs⟩ | ⟨pm, aidIs, callIs⟩
    · obtain ⟨k, lt, at_⟩ := labelled events _ noticeIn
      rw [aidIs, callIs]
      exact ⟨k, lt, events, sid, at_, assistant⟩
    · rw [aidIs, callIs]
      exact noticeBefore_mono (noticed pm) (by simp)
  · cases sources.dispatch step mem with
    | modelTurn record nmid progress entry phase nextId fresh checked => exact Or.inl (model_mode _ _ _)
    | notice now events entry cleanup authorized =>
      rw [notice_flags_aid]
      refine Or.inr ⟨by simp only [mkey_map_head], _, rfl, noticeBefore_mono (noticed entry.2) (by simp)⟩

theorem labelled_commit {log : List HostLabel} {pre post : List Term} {events : List Term} {opts mode : Term}
    (shape : StepShape (pre ++ commitEffect events opts mode :: post)) :
    ∀ events' opts', commitEffect events' opts' nil ∈ pre ++ commitEffect events opts mode :: post →
      ∃ k < (log ++ [HostLabel.commit events mode]).length,
        (log ++ [HostLabel.commit events mode])[k]? = some (.commit events' nil) := by
  intro events' opts' mem
  obtain ⟨rfl, rfl, rfl⟩ := commit_unique shape mem_of_commit_split mem
  exact ⟨log.length, by simp, by simp⟩

/-- One host transition keeps the notice invariant. -/
theorem noticeInv_step {cfg : HostConfig} (sources : StepSources) {log labels : List HostLabel}
    {σ σ' : HostState} (inv : NoticeInv log σ) (next : HostStep cfg σ labels σ') :
    NoticeInv (log ++ labels) σ' := by
  have ctl := inv.control
  cases next with
  | enter idle => exact noticeInv_mono inv (by no_dispatch) fun hp => (nil_not_phase _ hp).elim
  | request idle model granted => exact noticeInv_mono inv (by no_dispatch) fun hp => (nil_not_phase _ hp).elim
  | «local» feed step noCommit =>
    rw [feed] at ctl
    exact noticeInv_mono inv noDispatch_nil
      (noticed_step sources ctl step fun _ _ mem => (noCommit _ _ _ mem).elim)
  | reroute feed clean first step noCommit =>
    rw [feed] at ctl
    exact noticeInv_mono inv noDispatch_nil
      (noticed_step sources ctl step fun _ _ mem => (noCommit _ _ _ mem).elim)
  | commit feed clean first step land =>
    rw [feed] at ctl
    obtain ⟨noticed, modes⟩ := noticed_step (extra := [_]) sources ctl step
      (labelled_commit (sources.shape step))
    exact noticeInv_mono inv (by no_dispatch) ⟨noticed, fun calls flags mem => modes calls flags (mem_post mem)⟩
  | fenceCommit feed dirty step notSpeculative land cas =>
    rw [feed] at ctl
    obtain ⟨noticed, modes⟩ := noticed_step (extra := [_]) sources ctl step
      (labelled_commit (sources.shape step))
    exact noticeInv_mono inv (by no_dispatch) ⟨noticed, fun calls flags mem => modes calls flags (mem_post mem)⟩
  | @speculative machine event machine' t mode opts calls flags results async pre events mid
      feed step isSpeculative land executed cas =>
    have facts := stepOK_facts step machine' _ rfl
    refine ⟨fun i aid calls' mode' at_ => ?_, fun hp => ?_⟩
    · rcases label_split at_ with ⟨small, old⟩ | ⟨d, rfl, new⟩
      · exact modeRecorded_mono (inv.dispatched i aid calls' mode' old) (Nat.le_refl _)
      · rcases d with _ | _ | _ | _ | d <;> simp at new
    · exact ((facts.1 hp).2 calls flags (last_post List.getLast?_concat)).elim
  | speculativeFailed feed step isSpeculative land =>
    refine ⟨fun i aid calls' mode' at_ => ?_, trivial⟩
    rcases label_split at_ with ⟨small, old⟩ | ⟨d, rfl, new⟩
    · exact modeRecorded_mono (inv.dispatched i aid calls' mode' old) (Nat.le_refl _)
    · rcases d with _ | _ | _ | d <;> simp at new
  | skip perform kind =>
    rw [perform] at ctl
    exact noticeInv_mono inv noDispatch_nil (noticeControl_mono (c := .perform _ _)
      ⟨ctl.1, fun calls flags mem => ctl.2 calls flags (List.mem_cons_of_mem _ mem)⟩)
  | write perform land =>
    rw [perform] at ctl
    exact noticeInv_mono inv (by no_dispatch) (noticeControl_mono (c := .perform _ _)
      ⟨ctl.1, fun calls flags mem => ctl.2 calls flags (List.mem_cons_of_mem _ mem)⟩)
  | reply perform answer =>
    rw [perform] at ctl
    exact noticeInv_mono inv noDispatch_nil (noticed_mono ctl.1)
  | record perform built =>
    rw [perform] at ctl
    exact noticeInv_mono inv (by no_dispatch) (noticed_mono ctl.1)
  | @dispatch machine calls flags perform =>
    rw [perform] at ctl
    refine ⟨fun i aid calls' mode' at_ => ?_, noticed_mono ctl.1⟩
    rcases label_split at_ with ⟨small, old⟩ | ⟨d, rfl, new⟩
    · exact modeRecorded_mono (inv.dispatched i aid calls' mode' old) (Nat.le_refl _)
    · rcases d with _ | d <;> simp at new
      obtain ⟨rfl, rfl, rfl⟩ := new
      exact modeRecorded_mono (ctl.2 calls flags (List.mem_singleton_self _)) (by simp)
  | returned running executed =>
    rw [running] at ctl
    exact noticeInv_mono inv (by no_dispatch) (noticed_mono ctl)
  | planned perform =>
    rw [perform] at ctl
    exact noticeInv_mono inv (by no_dispatch) (noticed_mono ctl.1)
  | materialize perform plan land => exact noticeInv_mono inv (by no_dispatch) trivial
  | materializeRun perform plan land => exact noticeInv_mono inv (by no_dispatch) trivial
  | fast idle plan land =>
    exact noticeInv_mono inv (by no_dispatch) (by show NoticeControl _ σ.control; rw [idle]; trivial)
  | stop perform => exact noticeInv_mono inv (by no_dispatch) trivial
  | fence idle dirty cas => exact noticeInv_mono inv (by no_dispatch) (by rw [idle]; trivial)
  | refresh clean => exact noticeInv_mono inv noDispatch_nil (noticeControl_mono ctl)
  | env plan land => exact noticeInv_mono inv (by no_dispatch) (noticeControl_mono ctl)
  | abort busy => exact noticeInv_mono inv (by no_dispatch) trivial
  | crash => exact noticeInv_mono inv (by no_dispatch) trivial
  | restart idle clean plan land =>
    exact noticeInv_mono inv (by no_dispatch) (by show NoticeControl _ σ.control; rw [idle]; trivial)

theorem noticeInv_run {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) : NoticeInv log σ := by
  induction run with
  | refl => exact ⟨fun i aid calls mode h => by simp at h, by rw [init.1]; trivial⟩
  | step _ next ih => exact noticeInv_step stepSources ih next

/-- B1 for the runtime failure notice: a notice dispatch at position `i`
follows a durable commit, at `k < i`, of the kernel-built notice assistant
event at the same `aid` whose single call is the dispatched call. -/
theorem notice_after_durable_record {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {i : Nat} {aid calls : Term}
    (at_ : log[i]? = some (.dispatch aid calls (b "runtime_failure_notice") false)) :
    ∃ call, calls = list [call] ∧ ∃ k < i, ∃ events sid, log[k]? = some (.commit events nil) ∧
      noticeAssistant sid aid call ∈ events := by
  rcases (noticeInv_run run init).dispatched i aid calls _ at_ with model | ⟨_, call, eq, before⟩
  · exact absurd (text_inj.mp model) (by decide)
  · exact ⟨call, eq, before⟩

/-- Every non-speculative dispatch is a model turn or the runtime failure notice. -/
theorem dispatch_modes {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (init : HostInit σ₀) {i : Nat} {aid calls mode : Term}
    (at_ : log[i]? = some (.dispatch aid calls mode false)) :
    mode = b "model_turn" ∨ mode = b "runtime_failure_notice" := by
  rcases (noticeInv_run run init).dispatched i aid calls mode at_ with model | ⟨notice, _⟩
  · exact Or.inl model
  · exact Or.inr notice

end VerifiedKernel.Session.LoopProof.Dispatch
