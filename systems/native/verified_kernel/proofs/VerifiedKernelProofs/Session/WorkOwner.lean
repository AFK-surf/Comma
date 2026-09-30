import VerifiedKernelProofs.Session.WorkResidentEvidence
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

def OwnerFrame (s t : Term) : Prop := t.get (a "agent_id") = s.get (a "agent_id")

theorem owner_write {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (allowed : entries.all (fun entry => entry.1 != "agent_id") = true) : OwnerFrame s t :=
  write_field_frame h allowed

syntax "owner_walk" ident : tactic
macro_rules
  | `(tactic| owner_walk $h:ident) =>
    `(tactic| repeat' first
      | (head_is $h [write]; exact owner_write $h rfl)
      | (head_is $h [Pure.pure]; have same := pure_ok $h; cases same; rfl)
      | (head_is $h [VerifiedKernel.fail, argumentError, inspectedError]; exact (fail_ok $h).elim)
      | split at $h:ident
      | (obtain ⟨_, _, _, $h:ident⟩ := bind_ok $h)
      | dsimp only at $h:ident)

theorem appendFields_owner {s e m t : Term} {j r : List Term}
    (h : appendFields s e m j = .ok (t, r)) : OwnerFrame s t := by
  unfold appendFields at h
  owner_walk h

theorem bumpHwm_owner {s e t : Term} {j r : List Term}
    (h : bumpHwm s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold bumpHwm at h
  owner_walk h

theorem resetFresh_owner {s e t : Term} {j r : List Term}
    (h : resetFresh s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold resetFresh at h
  owner_walk h

theorem addObligation_owner {s e t : Term} {j r : List Term}
    (h : addObligation s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold addObligation at h
  owner_walk h

syntax "owner_chain" ident : tactic
macro_rules
  | `(tactic| owner_chain $h:ident) =>
    `(tactic| first
      | (head_is $h [appendFields]; exact appendFields_owner $h)
      | (head_is $h [bumpHwm]; exact bumpHwm_owner $h)
      | (head_is $h [resetFresh]; exact resetFresh_owner $h)
      | (head_is $h [addObligation]; exact addObligation_owner $h)
      | (head_is $h [write]; exact owner_write $h rfl))

syntax "owner_compose" ident : tactic
macro_rules
  | `(tactic| owner_compose $h:ident) =>
    `(tactic| repeat' first
      | owner_chain $h
      | (head_is $h [Pure.pure]; have same := pure_ok $h; cases same; rfl)
      | (head_is $h [VerifiedKernel.fail, argumentError, inspectedError]; exact (fail_ok $h).elim)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, _, prior, $h:ident⟩ := bind_ok $h
         first
           | (head_is prior [argumentError, VerifiedKernel.fail]; simp only [argumentError, fail_ok_iff] at prior)
           | (head_is prior [appendFields]; have kept := appendFields_owner prior; refine Eq.trans ?_ kept)
           | (head_is prior [bumpHwm]; have kept := bumpHwm_owner prior; refine Eq.trans ?_ kept)
           | (head_is prior [resetFresh]; have kept := resetFresh_owner prior; refine Eq.trans ?_ kept)
           | (head_is prior [addObligation]; have kept := addObligation_owner prior; refine Eq.trans ?_ kept)
           | (head_is prior [write]; have kept := owner_write prior rfl; refine Eq.trans ?_ kept)
           | skip)
      | dsimp only at $h:ident)

theorem queueAppend_owner {s e t : Term} {j r : List Term}
    (h : queueAppend s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold queueAppend at h
  owner_walk h

theorem transcriptLog_owner {s e t : Term} {j r : List Term}
    (h : transcriptLog s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold transcriptLog at h
  owner_compose h

theorem transcriptSeed_owner {s e t : Term} {j r : List Term}
    (h : transcriptSeed s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold transcriptSeed at h
  owner_compose h

theorem runtimeAppend_owner {s e t : Term} {j r : List Term}
    (h : runtimeAppend s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold runtimeAppend at h
  owner_compose h

theorem transcriptRuntime_owner {s e t : Term} {j r : List Term}
    (h : transcriptRuntime s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold transcriptRuntime at h
  repeat' first
    | (head_is h [runtimeAppend]; exact runtimeAppend_owner h)
    | (head_is h [VerifiedKernel.fail]; exact (fail_ok h).elim)
    | (head_is h [argumentError]; simp only [argumentError] at h; exact (fail_ok h).elim)
    | (head_is h [Pure.pure]; have same := pure_ok h; cases same; rfl)
    | split at h
    | (obtain ⟨_, _, prior, h⟩ := bind_ok h
       try (head_is prior [argumentError, VerifiedKernel.fail]; simp only [argumentError, fail_ok_iff] at prior))

theorem transcriptDelivery_owner {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold transcriptDelivery at h
  owner_compose h

theorem metadataCreated_owner {s e t : Term} {j r : List Term}
    (h : metadataCreated s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold metadataCreated at h
  owner_walk h

theorem sessionEvent_owner {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : OwnerFrame s t :=
  (sessionEvent_fields h).2 "agent_id" rfl

/-- Every permitted delivery reducer preserves the owning Agent. -/
theorem admitted_inner_owner {s e t : Term} {j r : List Term}
    (allowed : Command.inputEventAllowed e = true)
    (h : inner s e j = .ok (t, r)) : OwnerFrame s t := by
  simp only [Command.inputEventAllowed, List.contains_cons, List.contains_nil,
    Bool.or_false, Bool.or_eq_true, Bool.and_eq_true] at allowed
  rcases allowed with allowed | allowed
  · rcases allowed with allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed
    all_goals have kind := binary_beq_true allowed
    all_goals simp +decide [inner, kind] at h
    all_goals first
      | exact queueAppend_owner h
      | exact transcriptRuntime_owner h
      | exact transcriptDelivery_owner h
      | exact transcriptLog_owner h
      | exact transcriptSeed_owner h
      | exact metadataCreated_owner h
      | (have same := pure_ok h; cases same; rfl)
  · have kind := binary_beq_true allowed.1
    apply sessionEvent_owner
    simpa +decide [inner, kind] using h

/-- Ownership survives all resident observation/resume steps of an admitted delivery batch. -/
theorem admitted_resident_owner {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) : OwnerFrame s t := by
  induction execution with
  | nil => rfl
  | @cons state next final event events observations head tail ih =>
    obtain ⟨middle, normalized, j, r, prepared, activity⟩ := resident_execution_step head
    have first : OwnerFrame state middle := by
      cases normalized with
      | none => rw [prepareTrusted_none prepared]; rfl
      | some normalized =>
        obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
        have same := shallowStringify_binary_keys (canonical _ (by simp)) read
        subst normalized
        exact admitted_inner_owner (allowed _ (by simp)) reduced
    exact (ih (fun _ member => canonical _ (by simp [member]))
      (fun _ member => allowed _ (by simp [member]))).trans
      ((activity "agent_id" (by decide) (by decide)).trans first)

/-- The public input command supplies the batch contract used by the ownership proof. -/
theorem input_command_owner {s args result : Term} {j r : List Term}
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch ∧ ∀ t, ResidentBatch s batch t → OwnerFrame s t := by
  rcases input_start h with duplicate | saturated | invalid | ⟨batch, started, canonical, allowed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · exact Or.inr (Or.inr (Or.inr ⟨batch, started, fun _ execution =>
      admitted_resident_owner execution canonical (List.all_eq_true.mp allowed)⟩))

end VerifiedKernel.Session.WorkConservation
