import VerifiedKernelProofs.Session.WorkResident
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Session.WorkCanonical
import VerifiedKernelProofs.Session.WorkRouting
import VerifiedKernelProofs.Proof.NativeProducerTactic
import VerifiedKernelProofs.Loop.Budget

/-! # Session frames for bounded work (property C)

This module proves reducer facts that the budget proofs need.

* `resident_prepared`: a resident event execution is one successful
  `prepareTrusted` call, then a change of the activity fields only.
* The provider-wait yield: `provider_wait_yield_events` answers nothing or a
  `session_event`, a `wait_clear` without a `tool_call_id`, and an `ack`
  (`waitYieldEvents_shape`). After these events apply to a state of the same
  session, the session has no wait (`yield_clears_wait_of`).
  `activation_next` answers `yield` only for a session with a wait
  (`activationNext_yield_wait`). Thus it does not answer `yield` again
  (`yield_not_repeated`) until another write sets a wait.
-/

namespace VerifiedKernel.Session.Loop.RoundFrames
open Data
open VerifiedKernel.Session.WorkConservation
open VerifiedKernel.Session.Loop.Budget (Sat Sat.use)
set_option Elab.async false
set_option maxHeartbeats 1000000

/-! ## Resident execution -/

/-- One resident event execution: `prepareTrusted` succeeded with `next`, and
the activity reducer changed only the activity fields of `next`. -/
def Prepared (s e t : Term) : Prop :=
  ∃ next normalized j r, prepareTrusted s e j = .ok ((next, normalized), r) ∧ ActivityFrame next t

def PreparedToken (s e : Term) : Term → Prop
  | .tuple [.atom "reduce", current, event, .list _] => current = s ∧ event = e
  | .tuple [.atom "activity", resident, _, _, _, .list _] => Prepared s e resident
  | _ => False

def PreparedResult (s e : Term) : Term → Prop
  | .tuple [.atom "done", final] => Prepared s e final
  | .tuple [.atom "observe", _, token] => PreparedToken s e token
  | _ => True

theorem Prepared.frame {s e t u : Term} (h : Prepared s e t) (frame : ActivityFrame t u) : Prepared s e u := by
  obtain ⟨next, normalized, j, r, prepared, first⟩ := h
  exact ⟨next, normalized, j, r, prepared, activity_frame_trans first frame⟩

theorem put_activity (s x : Term) {key : String} (status : key = "activity_status" ∨ key = "activity_status_updated_at") :
    ActivityFrame s (s.put (a key) x) := by
  intro other one two
  apply get_put_other
  rcases status with rfl | rfl
  · exact fun same => one same.symm
  · exact fun same => two same.symm

theorem runActivityTrusted_prepared {s e next event : Term} {observations : List Term}
    (valid : Prepared s e next) :
    PreparedResult s e (runActivityTrusted s next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent s next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact valid.frame (afterEvent_activity_frame result)
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_prepared {s e : Term} {observations : List Term} :
    PreparedResult s e (runTrusted s e observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted s e observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      have here : Prepared s e next := ⟨next, normalized, _, _, result, activity_frame_refl _⟩
      cases normalized with
      | none => dsimp only; split <;> first | exact here | trivial
      | some event => dsimp only; exact runActivityTrusted_prepared here
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_prepared {s e token observation : Term} (valid : PreparedToken s e token) :
    PreparedResult s e (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · obtain ⟨same, sameEvent⟩ := valid
      subst same sameEvent
      exact runTrusted_prepared
    · rename_i resident current next event observations
      change Prepared s e resident at valid
      dsimp only
      cases result : afterEvent current next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change Prepared s e (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          split
          · exact (valid.frame (put_activity _ _ (Or.inl rfl))).frame (put_activity _ _ (Or.inr rfl))
          · exact valid.frame (put_activity _ _ (Or.inl rfl))
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

theorem resident_trace_prepared {s e initial final : Term} (trace : ResidentTrace initial final)
    (valid : PreparedResult s e initial) : PreparedResult s e final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_prepared valid)

/-- `resident_prepared`: a resident event execution is one successful
`prepareTrusted` call followed by activity-field changes. -/
theorem resident_prepared {s e t : Term} {observations : List Term}
    (trace : ResidentTrace (runTrusted s e observations) (.tuple [a "done", t])) : Prepared s e t :=
  resident_trace_prepared trace runTrusted_prepared

/-- A resident batch of three events, one step at a time. -/
theorem batch_three {s t e₁ e₂ e₃ : Term} (batch : ResidentBatch s [e₁, e₂, e₃] t) :
    ∃ s₁ s₂, Prepared s e₁ s₁ ∧ Prepared s₁ e₂ s₂ ∧ Prepared s₂ e₃ t := by
  cases batch with
  | cons one rest =>
    cases rest with
    | cons two rest =>
      cases rest with
      | cons three rest =>
        cases rest with
        | nil => exact ⟨_, _, resident_prepared one, resident_prepared two, resident_prepared three⟩

theorem Prepared.session {s e t : Term} (h : Prepared s e t) :
    t.get (a "session_id") = s.get (a "session_id") := by
  obtain ⟨next, normalized, j, r, prepared, frame⟩ := h
  rw [frame "session_id" (by decide) (by decide)]
  cases normalized with
  | none => rw [prepareTrusted_none prepared]
  | some event =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify prepared
    exact inner_session reduced

/-! ## The provider-wait yield -/

/-- The `wait_clear` event of the provider-wait yield. -/
def yieldClear (sid : Term) : Term := StateQuery.stringKeyed [("type", b "wait_clear"), ("session_id", sid)]

/-- The shape of a non-empty `provider_wait_yield_events` answer: a
`session_event`, then the `wait_clear` of the session, then an `ack`. -/
def YieldShape (s : Term) (events : List Term) : Prop :=
  ∃ first last, events = [first, yieldClear (s.get (a "session_id")), last] ∧
    BinaryKeys last ∧ last.get (b "type") = b "ack"

theorem field_value {s v : Term} {name : String} {j j' : List Term} (h : field s name j = .ok (v, j')) :
    v = s.get (a name) := by
  simp only [field, fetch_ok_iff] at h
  exact h.2.2.1

theorem waitYieldEvents_shape {s expected : Term} :
    Sat (fun v => v = list [] ∨ ∃ events, v = list events ∧ YieldShape s events)
      (StateQuery.waitYieldEvents s expected) := by
  unfold StateQuery.waitYieldEvents
  sat_walk
  all_goals first
    | exact Or.inl rfl
    | (right
       rename_i read _ _ _ _ _ _ _ _
       rw [field_value read]
       exact ⟨_, rfl, _, _, rfl, stringKeyed_binary_keys _, by simp +decide [StateQuery.stringKeyed, Term.get]⟩)

theorem pruneResultRefs_wait {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : t.get (a "wait") = s.get (a "wait") := by
  unfold pruneResultRefs at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem sessionAck_wait {s e t : Term} {j r : List Term}
    (h : sessionAck s e j = .ok (t, r)) : t.get (a "wait") = s.get (a "wait") := by
  unfold sessionAck at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

/-- A `wait_clear` without a `tool_call_id` clears the wait. -/
theorem waitClear_nil {s e t : Term} {j r : List Term} (untargeted : e.get (b "tool_call_id") = nil)
    (h : waitClear s e j = .ok (t, r)) : t.get (a "wait") = nil := by
  unfold waitClear at h
  rw [untargeted] at h
  have absent : presentString nil = false := by decide
  simp only [absent, Bool.false_eq_true, if_false] at h
  obtain ⟨cleared, _, written, pruned⟩ := bind_ok h
  rw [pruneResultRefs_wait pruned]
  obtain ⟨_, written⟩ := write_cons written
  rw [pure_ok written]
  exact get_put_same _ _ _

theorem inner_wait_clear {s e t : Term} {j r : List Term} (kind : e.get (b "type") = b "wait_clear")
    (untargeted : e.get (b "tool_call_id") = nil) (h : inner s e j = .ok (t, r)) : t.get (a "wait") = nil := by
  apply waitClear_nil untargeted
  simpa +decide [inner, kind] using h

theorem inner_ack_wait {s e t : Term} {j r : List Term} (kind : e.get (b "type") = b "ack")
    (h : inner s e j = .ok (t, r)) : t.get (a "wait") = s.get (a "wait") := by
  apply sessionAck_wait
  simpa +decide [inner, kind] using h

/-- After the provider-wait yield events apply to a state of the same session,
the session has no wait. The `wait_clear` event has no `tool_call_id`, so it
clears any wait. -/
theorem yield_clears_wait_of {s₀ s t : Term} {events : List Term} (shape : YieldShape s₀ events)
    (same : s.get (a "session_id") = s₀.get (a "session_id"))
    (land : ResidentBatch s events t) : t.get (a "wait") = nil := by
  obtain ⟨first, last, rfl, keys, kind⟩ := shape
  obtain ⟨s₁, s₂, one, two, three⟩ := batch_three land
  have sid : s₁.get (a "session_id") = s₀.get (a "session_id") := one.session.trans same
  have target : (yieldClear (s₀.get (a "session_id"))).get (b "session_id") = s₀.get (a "session_id") := by
    simp +decide [yieldClear, StateQuery.stringKeyed, Term.get]
  have cleared : s₂.get (a "wait") = nil := by
    obtain ⟨next, normalized, j, r, prepared, frame⟩ := two
    rw [frame "wait" (by decide) (by decide)]
    cases normalized with
    | none =>
      exact (prepareTrusted_canonical_not_skipped (stringKeyed_binary_keys _) (target.trans sid.symm)
        prepared).elim
    | some event =>
      obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys (stringKeyed_binary_keys _) read
      subst same
      exact inner_wait_clear (by simp +decide [yieldClear, StateQuery.stringKeyed, Term.get])
        (by simp +decide [yieldClear, StateQuery.stringKeyed, Term.get, nil]) reduced
  obtain ⟨next, normalized, j, r, prepared, frame⟩ := three
  rw [frame "wait" (by decide) (by decide)]
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact cleared
  | some event =>
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys keys read
    subst same
    rw [inner_ack_wait kind reduced]
    exact cleared

/-- After the provider-wait yield events apply, the session has no wait. -/
theorem yield_clears_wait {s t : Term} {events : List Term} (shape : YieldShape s events)
    (land : ResidentBatch s events t) : t.get (a "wait") = nil :=
  yield_clears_wait_of shape rfl land

/-- `yieldable_provider_wait?` holds only for a session with a wait map. -/
theorem yieldable_wait {s : Term} {j j' : List Term}
    (h : StateQuery.yieldableProviderWait s j = .ok (true, j')) : (s.get (a "wait")).isMap = true := by
  unfold StateQuery.yieldableProviderWait at h
  split at h
  all_goals
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · cases pure_ok h
    obtain ⟨wait, _, read, h⟩ := bind_ok h
    split at h
    · cases pure_ok h
    rename_i open_
    rw [field_value read] at open_
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] at open_
    exact open_.1

theorem activationNext_yield_wait {state r : Term} :
    Sat (fun out => out = a "yield" → (state.get (a "wait")).isMap = true)
      (Budget.activationNextN state r) := by
  unfold Budget.activationNextN
  unfold_native "VerifiedKernel.Session.Command.activationNext"
  sat_walk
  all_goals first
    | (intro _; subst_vars; exact yieldable_wait ‹_›)
    | (intro h; simp [a] at h)
    | (intro h; cases h)

theorem lookup_yield_events :
    lookupOp queryTable (a "provider_wait_yield_events") = some StateQuery.waitYieldEvents := rfl

theorem queryAsk_yield_events (state x : Term) :
    Loop.queryAsk state "provider_wait_yield_events" x = StateQuery.waitYieldEvents state x := by
  unfold Loop.queryAsk
  rw [lookup_yield_events]

/-- `yield_not_repeated`: the loop's yield branch writes the answer of
`provider_wait_yield_events`. After those events apply to the state that the
step read, `activation_next` does not answer `yield`, for any Router fact. -/
theorem yield_not_repeated {s t expected r : Term} {events : List Term} {j j' : List Term}
    (yield : Loop.queryAsk s "provider_wait_yield_events" expected j = .ok (list events, j'))
    (nonempty : events ≠ []) (land : ResidentBatch s events t) :
    ¬ LoopProof.Returns (Loop.queryAsk t "activation_next" r) (a "yield") := by
  rw [queryAsk_yield_events] at yield
  rcases Sat.use waitYieldEvents_shape yield with empty | ⟨events', same, shape⟩
  · cases empty
    exact absurd rfl nonempty
  · cases same
    intro ⟨k, k', answered⟩
    rw [Budget.queryAsk_activation_next] at answered
    have isMap := Sat.use activationNext_yield_wait answered rfl
    rw [yield_clears_wait shape land] at isMap
    cases isMap

end VerifiedKernel.Session.Loop.RoundFrames
