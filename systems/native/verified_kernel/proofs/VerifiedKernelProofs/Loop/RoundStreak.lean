import VerifiedKernelProofs.Session.WorkResident
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Session.WorkCanonical
import VerifiedKernelProofs.Proof.NativeProducerTactic
import VerifiedKernelProofs.Loop.RoundFrames

/-! # The round budget frame (property C)

`input_round_streak` counts the assistant rounds since the last fresh input.
This module proves which reducers change it:

* `transcriptAssistant` (event type `assistant`) stores one more round;
* `sessionAck` (event type `ack`) clears it when the ACK advances, unless the
  event carries `keep_round_budget`;
* `resetFresh`, through `transcriptDelivery` (`delivery`) and
  `transcriptRuntime` (`runtime_message`), clears it for fresh input;
* every other reducer keeps it (`inner_round`).
-/

namespace VerifiedKernel.Session.Loop.RoundStreak
open Data
open VerifiedKernel.Session.WorkConservation
open VerifiedKernel.Session.Loop.RoundFrames (Prepared resident_prepared)
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- The stored round budget field. -/
def rounds (s : Term) : Term := s.get (a "input_round_streak")

/-- The reducer keeps the stored round budget. -/
def RoundKept (s t : Term) : Prop := rounds t = rounds s

theorem round_kept_refl (s : Term) : RoundKept s s := rfl

theorem round_kept_trans {s t u : Term} (first : RoundKept s t) (second : RoundKept t u) : RoundKept s u :=
  second.trans first

theorem write_round_kept_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "input_round_streak") = true → RoundKept s t) :=
  step_iff fun h ok => write_field_frame h ok

syntax "round_kept_step" ident : tactic
macro_rules
  | `(tactic| round_kept_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_round_kept_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine round_kept_trans (kept rfl) ?_)
      | (head_step $h "_round_kept_step"; obtain ⟨_, kept⟩ := $h; refine round_kept_trans kept ?_))

syntax "round_kept_walk" ident : tactic
macro_rules
  | `(tactic| round_kept_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact round_kept_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (round_kept_step $h; exact round_kept_refl _)
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
           | round_kept_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | round_kept_step $hx
               | ((repeat (fail_if_success round_kept_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  round_kept_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

/-- `round_rule f (state x y)` proves `f_round_kept` and `f_round_kept_step` by the walk. -/
syntax "round_rule " ident " (" ident+ ")" : command
macro_rules
  | `(round_rule $fn:ident ($args:ident*)) => do
    let lemma := Lean.mkIdent (fn.getId.appendAfter "_round_kept")
    let step := Lean.mkIdent (fn.getId.appendAfter "_round_kept_step")
    let state := args[0]!
    let binders ← args.mapM (fun arg => `(bracketedBinder| {$arg : Term}))
    let applied ← args.foldlM (fun acc arg => `(term| $acc $arg)) (← `(term| $fn))
    let first ← `(command|
      theorem $lemma $binders:bracketedBinder* {next : Term} {journal rest : List Term}
          (call : $applied journal = .ok (next, rest)) : RoundKept $state next := by
        unfold $fn at call
        round_kept_walk call)
    let second ← `(command|
      theorem $step $binders:bracketedBinder* {next : Term} {journal rest : List Term} :
          $applied journal = .ok (next, rest) ↔
            Except.ok (next, rest) = $applied journal ∧ RoundKept $state next := step_iff $lemma)
    return Lean.mkNullNode #[first, second]

round_rule appendFields (state event message)
round_rule bumpHwm (state hwm)
round_rule appendMessage (state event message)
round_rule noteResult (state tool input status errorClass message content)
round_rule noteAsyncResult (state existing event status)
round_rule asyncStart (state event)
round_rule asyncTerminal (state event status)
round_rule replyRepair (state event)
round_rule replyIntent (state event)
round_rule retireIntent (state event)
round_rule activationStarted (state raw)
round_rule activationFinished (state identity)
round_rule pruneResultRefs (state)
round_rule waitClear (state event)
round_rule statusTransition (state event)
round_rule activityTransition (state event)
round_rule metadataCreated (state event)
round_rule conversationSourceAdvance (state event)
round_rule metadataPrompt (state event)
round_rule metadataUpdate (state event)
round_rule stampWorkReasons (state event)
round_rule stampAgentId (state event)
round_rule stampRuntimeEpoch (state event)
round_rule stampRuntimeNode (state event)
round_rule stampActivityRevision (state event)
round_rule stampStorageRevision (state event)
round_rule stampFlushId (state event)
round_rule stampWorkIndexToken (state event)
round_rule sessionStamp (state event)
round_rule bumpHwmEvent (state event)
round_rule compactionFailure (state event)
round_rule compactionRecovery (state event)
round_rule progressStep (state event)
round_rule pruneCompactResults (state)
round_rule recomputeContext (state)

set_option backward.split false in
theorem historyCompaction_round_kept {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : RoundKept s t := by
  unfold historyCompaction at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.recomputeContext"
       exact recomputeContext_round_kept h)
    | (execution_head_is h "Pure.pure"
       have same := pure_ok h
       subst t
       exact round_kept_refl _)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine round_kept_trans (write_field_frame prior rfl) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneResultRefs"
            refine round_kept_trans (pruneResultRefs_round_kept prior) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneCompactResults"
            refine round_kept_trans (pruneCompactResults_round_kept prior) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem historyCompaction_round_kept_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔
      Except.ok (t, r) = historyCompaction s e provider j ∧ RoundKept s t :=
  step_iff historyCompaction_round_kept

round_rule compactResult (state event)
round_rule storedResult (state event)
round_rule transcriptToolResult (state event)
round_rule transcriptLog (state event)
round_rule transcriptSeed (state event)
round_rule queueAppend (state event)
round_rule queueAck (state event)
round_rule queueConsume (state event)
/-- `sessionEvent` writes only `sessionEventWrittenKeys`. This frame is much cheaper than a
walk over every branch of `sessionEvent`. -/
theorem sessionEvent_round_kept {state event next : Term} {journal rest : List Term}
    (call : sessionEvent state event journal = .ok (next, rest)) : RoundKept state next :=
  (sessionEvent_fields call).2 "input_round_streak" rfl

theorem sessionEvent_round_kept_step {state event next : Term} {journal rest : List Term} :
    sessionEvent state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = sessionEvent state event journal ∧ RoundKept state next :=
  step_iff sessionEvent_round_kept

theorem mergePredicate_round_kept {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) : RoundKept s t := by
  unfold mergePredicate at h
  repeat' first
    | exact (write_field_frame h rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem mergePredicate_round_kept_step {s kind through replacement extra t : Term} {j r : List Term} :
    mergePredicate s kind through replacement extra j = .ok (t, r) ↔
      Except.ok (t, r) = mergePredicate s kind through replacement extra j ∧ RoundKept s t :=
  step_iff mergePredicate_round_kept

theorem microcompactIds_round_kept {s replacement e t : Term} {ids j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) : RoundKept s t := by
  unfold microcompactIds at h
  round_kept_walk h

theorem microcompactIds_round_kept_step {s replacement e t : Term} {ids j r : List Term} :
    microcompactIds s ids replacement e j = .ok (t, r) ↔
      Except.ok (t, r) = microcompactIds s ids replacement e j ∧ RoundKept s t :=
  step_iff microcompactIds_round_kept

round_rule microcompact (state event)
round_rule capabilitySync (state event)
round_rule archiveAdvance (state event)

/-- The activity reducer changes only the two activity fields. -/
theorem afterEvent_round_kept {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : RoundKept next t := by
  unfold afterEvent at h
  round_kept_walk h


round_rule addObligation (state raw)
round_rule obligationResolve (state key)
round_rule obligationCard (state conversation limit)

theorem write_entry_last {s t v : Term} {name : String} {pre post : List (String × Term)} {j r : List Term}
    (h : write s (pre ++ (name, v) :: post) j = .ok (t, r))
    (later : post.all (fun entry => entry.1 != name) = true) : t.get (a name) = v := by
  induction pre generalizing s j with
  | nil =>
    obtain ⟨j', h⟩ := write_cons h
    rw [write_field_frame h later, get_put_same]
  | cons entry rest ih =>
    obtain ⟨j', h⟩ := write_cons (k := entry.1) (v := entry.2) h
    exact ih h

/-! ## Reducers that clear the round budget -/

/-- The round budget is kept or cleared. -/
def RoundReset (s t : Term) : Prop := RoundKept s t ∨ rounds t = nil

theorem reset_of_kept {s t u : Term} (first : RoundKept s t) (second : RoundReset t u) : RoundReset s u := by
  rcases second with kept | cleared
  · exact Or.inl (round_kept_trans first kept)
  · exact Or.inr cleared

/-- `resetFresh` keeps the round budget for a background completion or a wait
expiry and clears it for fresh input. -/
theorem resetFresh_round {s m t : Term} {j r : List Term} (h : resetFresh s m j = .ok (t, r)) :
    RoundReset s t := by
  unfold resetFresh at h
  obtain ⟨pending, _, _, h⟩ := bind_ok h
  split at h
  · left; rw [pure_ok h]; rfl
  obtain ⟨source, _, _, h⟩ := bind_ok h
  obtain ⟨kind, _, _, h⟩ := bind_ok h
  dsimp only at h
  split at h <;>
  · obtain ⟨repeated, _, _, h⟩ := bind_ok h
    try dsimp only at h
    split at h <;>
    · obtain ⟨value, _, read, h⟩ := bind_ok h
      obtain ⟨current, _, _, h⟩ := bind_ok h
      have last := write_entry_last (pre := [(_, _), (_, _)]) h rfl
      first
        | (left; unfold RoundKept rounds; rw [last]; simp only [field, fetch_ok_iff] at read; exact read.2.2.1)
        | (right; unfold rounds; rw [last, pure_ok read])

theorem resetFresh_round_reset_step {s m t : Term} {j r : List Term} :
    resetFresh s m j = .ok (t, r) ↔ Except.ok (t, r) = resetFresh s m j ∧ RoundReset s t :=
  step_iff resetFresh_round

syntax "reset_walk" ident : tactic
macro_rules
  | `(tactic| reset_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact Or.inl (round_kept_refl _))
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (head_is $h [resetFresh]; exact resetFresh_round $h)
      | (head_is $h [runtimeAppend]; exact runtimeAppend_round $h)
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
           | (head_is $hx [write]; simp only [write_round_kept_step] at $hx:ident; obtain ⟨_, kept⟩ := $hx
              refine reset_of_kept (kept rfl) ?_)
           | (head_step $hx "_round_kept_step"; obtain ⟨_, kept⟩ := $hx; refine reset_of_kept kept ?_)
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | (head_is $hx [write]; simp only [write_round_kept_step] at $hx:ident; obtain ⟨_, kept⟩ := $hx
                  refine reset_of_kept (kept rfl) ?_)
               | (head_step $hx "_round_kept_step"; obtain ⟨_, kept⟩ := $hx; refine reset_of_kept kept ?_)
               | skip)
           | skip)
      | dsimp only at $h:ident)

/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). This is much
cheaper than a walk over every branch of `runtimeAppend`. -/
theorem runtimeAppend_round {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    RoundReset s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops h
  exact reset_of_kept (appendFields_round_kept appended) (reset_of_kept (write_field_frame written rfl)
    (reset_of_kept (bumpHwm_round_kept bumped) (resetFresh_round reset)))

theorem transcriptRuntime_round {s e t : Term} {j r : List Term} (h : transcriptRuntime s e j = .ok (t, r)) :
    RoundReset s t := by
  unfold transcriptRuntime at h
  split at h
  · left; rw [pure_ok h]; rfl
  obtain ⟨keys, _, _, h⟩ := bind_ok h
  dsimp only at h
  split at h
  · obtain ⟨_, _, err, _⟩ := bind_ok h
    simp only [argumentError, fail_ok_iff] at err
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    try dsimp only at h
    split at h
    · obtain ⟨_, _, err, _⟩ := bind_ok h
      simp only [argumentError, fail_ok_iff] at err
    · exact runtimeAppend_round h

/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). This is
much cheaper than a walk over every branch of `transcriptDelivery`. -/
theorem transcriptDelivery_round {s e t : Term} {j r : List Term} (h : transcriptDelivery s e j = .ok (t, r)) :
    RoundReset s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, obligated, bumped, reset⟩
  · exact Or.inl (round_kept_refl _)
  · exact reset_of_kept (appendFields_round_kept appended) (reset_of_kept (write_field_frame written rfl)
      (reset_of_kept (addObligation_round_kept obligated) (reset_of_kept (bumpHwm_round_kept bumped)
        (resetFresh_round reset))))

set_option backward.split false in
/-- An ACK keeps the round budget, or it clears it and carries no
`keep_round_budget` mark. -/
theorem sessionAck_round {s e t : Term} {j r : List Term} (call : sessionAck s e j = .ok (t, r)) :
    RoundKept s t ∨ (rounds t = nil ∧ (e.get (b "keep_round_budget") == a "true") = false) := by
  unfold sessionAck at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨advanced, _, _, call⟩ := bind_ok call
  split at call
  · left; rw [pure_ok call]; rfl
  obtain ⟨keep, _, kread, call⟩ := bind_ok call
  have keepValue := (access_ok kread).1
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨current, _, read, call⟩ := bind_ok call
  simp only [field, fetch_ok_iff] at read
  obtain ⟨_, _, same, _⟩ := read
  obtain ⟨_, _, _, call⟩ := bind_ok call
  have last := write_entry_last
    (pre := [("last_ack_message_id", _), ("provider_reply_obligations", _), ("active_source_message_ids", _),
      ("visible_reply_activation_scope", _), ("visible_reply_egress_facts", _), ("runaway_unsettled_streak", _)])
    call rfl
  unfold RoundKept rounds
  rw [last]
  unfold clearedWhen
  split
  · rename_i cleared
    right
    refine ⟨rfl, ?_⟩
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at cleared
    rw [← keepValue]
    exact cleared.2
  · left; exact same

theorem streakCount_integer (v : Term) : ∃ n : Int, 0 ≤ n ∧ streakCount v = .integer n := by
  unfold streakCount
  dsimp only
  split
  · rename_i h
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h
    obtain ⟨isInt, pos⟩ := h
    cases hc : v.get (b "count") with
    | integer n => exact ⟨n, by rw [hc] at pos; simp [integerValue] at pos; omega, rfl⟩
    | _ => rw [hc] at isInt; simp [Term.isInteger] at isInt
  · exact ⟨0, Int.le_refl 0, rfl⟩

/-- An assistant message stores one more round. -/
theorem transcriptAssistant_round {s e t : Term} {j r : List Term} (h : transcriptAssistant s e j = .ok (t, r)) :
    ∃ n : Int, 0 ≤ n ∧ streakCount (rounds s) = .integer n ∧ rounds t = .map [(b "count", .integer (n + 1))] := by
  unfold transcriptAssistant at h
  iterate 13 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨appended, _, app, h⟩ := bind_ok h
  have kept := appendMessage_round_kept app
  obtain ⟨v, _, read, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at read
  obtain ⟨_, _, same, _⟩ := read
  obtain ⟨c, _, added, h⟩ := bind_ok h
  obtain ⟨n, nonneg, count⟩ := streakCount_integer (rounds s)
  have value : v = rounds s := by rw [same]; exact kept
  rw [value, count] at added
  rw [add_integer] at added
  simp only [Except.ok.injEq, Prod.mk.injEq] at added
  obtain ⟨rfl, _⟩ := added
  obtain ⟨_, h⟩ := write_cons h
  refine ⟨n, nonneg, count, ?_⟩
  unfold rounds
  rw [pure_ok h, get_put_same]

/-! ## One reducer step -/

/-- What one reducer step does to the stored round budget. -/
def RoundEffect (e s t : Term) : Prop :=
  RoundKept s t ∨
  ((e.get (b "type") == b "assistant") = true ∧ ∃ n : Int, 0 ≤ n ∧ streakCount (rounds s) = .integer n ∧
    rounds t = .map [(b "count", .integer (n + 1))]) ∨
  ((e.get (b "type") == b "ack") = true ∧ rounds t = nil ∧ (e.get (b "keep_round_budget") == a "true") = false) ∨
  (((e.get (b "type") == b "delivery") = true ∨ (e.get (b "type") == b "runtime_message") = true) ∧ rounds t = nil)

/-- `inner_round`: an `assistant` event stores one more round, an unmarked
advancing `ack` or a `delivery` or `runtime_message` can clear the count, and
every other event keeps it. -/
theorem inner_round {s e t : Term} {j r : List Term} (h : inner s e j = .ok (t, r)) : RoundEffect e s t := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := (h : _ ∨ _))
  all_goals first
    | (head_is h [transcriptAssistant]
       exact Or.inr (Or.inl ⟨‹_›, transcriptAssistant_round h⟩))
    | (head_is h [sessionAck]
       rcases sessionAck_round h with kept | ⟨cleared, keep⟩
       · exact Or.inl kept
       · exact Or.inr (Or.inr (Or.inl ⟨‹_›, cleared, keep⟩)))
    | (head_is h [transcriptDelivery]
       rcases transcriptDelivery_round h with kept | cleared
       · exact Or.inl kept
       · exact Or.inr (Or.inr (Or.inr ⟨Or.inl ‹_›, cleared⟩)))
    | (head_is h [transcriptRuntime]
       rcases transcriptRuntime_round h with kept | cleared
       · exact Or.inl kept
       · exact Or.inr (Or.inr (Or.inr ⟨Or.inr ‹_›, cleared⟩)))
    | (left; round_kept_walk h)

/-! ## Batches -/

/-- The round count that the guards read before the ACK test: `streakCount`
of the stored field. -/
def roundCount (s : Term) : Int := integerValue (streakCount (rounds s))

/-- An event that can clear the round budget: an `ack` without the
`keep_round_budget` mark, a `delivery`, or a `runtime_message`. -/
def ResetEvent (e : Term) : Prop :=
  ((e.get (b "type") == b "ack") = true ∧ (e.get (b "keep_round_budget") == a "true") = false) ∨
  (e.get (b "type") == b "delivery") = true ∨ (e.get (b "type") == b "runtime_message") = true

theorem streakCount_next (n : Int) (nonneg : 0 ≤ n) :
    streakCount (.map [(b "count", .integer (n + 1))]) = .integer (n + 1) := by
  unfold streakCount
  have : (b "count" == b "count") = true := by rw [binary_key_beq]; rfl
  simp [Term.get, List.find?, this, Term.isInteger, integerValue]
  omega

theorem roundCount_nonneg (s : Term) : 0 ≤ roundCount s := by
  obtain ⟨n, nonneg, count⟩ := streakCount_integer (rounds s)
  unfold roundCount; rw [count]; simpa [integerValue] using nonneg

/-- Without a reset event, one reducer step keeps or raises the round count. -/
theorem RoundEffect.mono {e s t : Term} (eff : RoundEffect e s t) (quiet : ¬ ResetEvent e) :
    roundCount s ≤ roundCount t := by
  rcases eff with kept | ⟨kind, n, nonneg, before, after⟩ | ⟨kind, _, keep⟩ | ⟨kind, _⟩
  · unfold roundCount; rw [kept]; exact Int.le_refl _
  · unfold roundCount
    rw [before, after, streakCount_next n nonneg]
    simp [integerValue]
    omega
  · exact (quiet (Or.inl ⟨kind, keep⟩)).elim
  · rcases kind with k | k
    · exact (quiet (Or.inr (Or.inl k))).elim
    · exact (quiet (Or.inr (Or.inr k))).elim

/-- An `assistant` event raises the round count by one. -/
theorem inner_assistant_count {s e t : Term} {j r : List Term} (kind : e.get (b "type") = b "assistant")
    (h : inner s e j = .ok (t, r)) : roundCount t = roundCount s + 1 := by
  have call : transcriptAssistant s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
  obtain ⟨n, nonneg, before, after⟩ := transcriptAssistant_round call
  unfold roundCount
  rw [before, after, streakCount_next n nonneg]
  simp [integerValue]

theorem activity_rounds {s t : Term} (frame : ActivityFrame s t) : rounds t = rounds s :=
  frame "input_round_streak" (by decide) (by decide)

/-- A raw event whose normalized form is not a reset event. -/
def RawQuiet (raw : Term) : Prop := ∀ event j r, shallowStringify raw j = .ok (event, r) → ¬ ResetEvent event

/-- One resident event execution without a reset event keeps or raises the round count. -/
theorem prepared_rounds {s raw t : Term} (step : Prepared s raw t) (quiet : RawQuiet raw) :
    roundCount s ≤ roundCount t := by
  obtain ⟨next, normalized, j, r, prepared, frame⟩ := step
  have same : roundCount t = roundCount next := by unfold roundCount; rw [activity_rounds frame]
  rw [same]
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact Int.le_refl _
  | some event =>
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
    exact (inner_round reduced).mono (quiet _ _ _ read)

/-- `batch_rounds`: a resident batch without a reset event never lowers the
round count. Only an unmarked `ack`, a `delivery` or a `runtime_message` can
start the round budget over. -/
theorem batch_rounds {s t : Term} {events : List Term} (batch : ResidentBatch s events t)
    (quiet : ∀ raw ∈ events, RawQuiet raw) : roundCount s ≤ roundCount t := by
  induction batch with
  | nil => exact Int.le_refl _
  | cons head tail ih =>
    exact Int.le_trans (prepared_rounds (resident_prepared head) (quiet _ List.mem_cons_self))
      (ih (fun raw mem => quiet raw (List.mem_cons_of_mem _ mem)))

/-- A binary-keyed `assistant` event of the session raises the round count by one. -/
theorem prepared_assistant {s raw t : Term} (step : Prepared s raw t) (keys : BinaryKeys raw)
    (target : raw.get (b "session_id") = s.get (a "session_id")) (kind : raw.get (b "type") = b "assistant") :
    roundCount t = roundCount s + 1 := by
  obtain ⟨next, normalized, j, r, prepared, frame⟩ := step
  have same : roundCount t = roundCount next := by unfold roundCount; rw [activity_rounds frame]
  rw [same]
  cases normalized with
  | none => exact (prepareTrusted_canonical_not_skipped keys target prepared).elim
  | some event =>
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
    have e := shallowStringify_binary_keys keys read
    subst e
    exact inner_assistant_count kind reduced

end VerifiedKernel.Session.Loop.RoundStreak
