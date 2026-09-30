import VerifiedKernelProofs.Session.WorkLedgerInput
import VerifiedKernelProofs.Session.WorkReady

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

def ActivityFrame (s t : Term) : Prop :=
  ∀ key : String, key ≠ "activity_status" → key ≠ "activity_status_updated_at" →
    t.get (a key) = s.get (a key)

theorem activity_frame_refl (s : Term) : ActivityFrame s s := fun _ _ _ => rfl

theorem activity_frame_trans {s t u : Term} (first : ActivityFrame s t) (second : ActivityFrame t u) :
    ActivityFrame s u := fun key one two => (second key one two).trans (first key one two)

theorem afterEvent_activity_frame {previous next event final : Term} {j r : List Term}
    (h : afterEvent previous next event j = .ok (final, r)) : ActivityFrame next final := by
  intro key notStatus notTime
  unfold afterEvent at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨derived, _, written, h⟩ := bind_ok h
  have frame := write_field_frame (key := key) written (by simp [Ne.symm notStatus])
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]; exact frame
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · exact (write_field_frame h (by simp [Ne.symm notTime])).trans frame
    · rw [pure_ok h]; exact frame

def EventPreserves (P : Term → Prop) (state event : Term) : Prop :=
  ∀ next normalized j r, prepareTrusted state event j = .ok ((next, normalized), r) → P next

def SafeResidentToken (P : Term → Prop) : Term → Prop
  | .tuple [.atom "reduce", state, event, .list _] => P state ∧ EventPreserves P state event
  | .tuple [.atom "activity", resident, _, _, _, .list _] => P resident
  | _ => False

def SafeResidentResult (P : Term → Prop) : Term → Prop
  | .tuple [.atom "done", state] => P state
  | .tuple [.atom "observe", _, token] => SafeResidentToken P token
  | _ => True

theorem runActivityTrusted_safe {P : Term → Prop} {state next event : Term} {observations : List Term}
    (valid : P next)
    (activityClosed : ∀ s t, P s → ActivityFrame s t → P t) :
    SafeResidentResult P (runActivityTrusted state next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent state next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact activityClosed _ _ valid (afterEvent_activity_frame result)
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_safe {P : Term → Prop} {state event : Term} {observations : List Term}
    (valid : P state) (admitted : EventPreserves P state event)
    (activityClosed : ∀ s t, P s → ActivityFrame s t → P t) :
    SafeResidentResult P (runTrusted state event observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted state event observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      have kept := admitted next normalized _ _ result
      cases normalized with
      | none => dsimp only; split <;> first | exact kept | trivial
      | some event => dsimp only; exact runActivityTrusted_safe kept activityClosed
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨valid, admitted⟩ | trivial

theorem resumeTrusted_safe {P : Term → Prop} {token observation : Term}
    (valid : SafeResidentToken P token)
    (activityClosed : ∀ s t, P s → ActivityFrame s t → P t) :
    SafeResidentResult P (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · dsimp only [SafeResidentToken] at valid
      exact runTrusted_safe valid.1 valid.2 activityClosed
    · rename_i resident state next event observations
      change P resident at valid
      dsimp only
      cases result : afterEvent state next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change P (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          apply activityClosed resident _ valid
          intro key notStatus notTime
          split
          · rw [get_put_other _ _ (Ne.symm notTime), get_put_other _ _ (Ne.symm notStatus)]
          · exact get_put_other _ _ (Ne.symm notStatus)
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

inductive ResidentTrace : Term → Term → Prop where
  | done (result : Term) : ResidentTrace result result
  | resume {request token observation result : Term}
      (tail : ResidentTrace (resumeTrusted token observation) result) :
      ResidentTrace (.tuple [a "observe", request, token]) result

theorem resident_trace_safe {P : Term → Prop} {initial final : Term}
    (trace : ResidentTrace initial final) (valid : SafeResidentResult P initial)
    (activityClosed : ∀ s t, P s → ActivityFrame s t → P t) : SafeResidentResult P final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_safe valid activityClosed)

theorem resident_execution_preserves {P : Term → Prop} {state event final : Term} {observations : List Term}
    (valid : P state) (admitted : EventPreserves P state event)
    (activityClosed : ∀ s t, P s → ActivityFrame s t → P t)
    (trace : ResidentTrace (runTrusted state event observations) (.tuple [a "done", final])) : P final :=
  resident_trace_safe trace (runTrusted_safe valid admitted activityClosed) activityClosed

theorem activity_frame_queue {s t : Term} (frame : ActivityFrame s t) : QueueFrame s t := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  all_goals exact frame _ (by decide) (by decide)

theorem activity_frame_work {s t : Term} (frame : ActivityFrame s t) : WorkFieldsPreserved s t := by
  exact ⟨frame _ (by decide) (by decide), frame _ (by decide) (by decide)⟩

theorem resident_input_safety {s e t : Term} {observations : List Term}
    (ready : QueueReady s) (canonical : BinaryKeys e) (allowed : Command.inputEventAllowed e = true)
    (trace : ResidentTrace (runTrusted s e observations) (.tuple [a "done", t])) :
    QueueReady t ∧ ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  apply resident_execution_preserves
    (P := fun state => QueueReady state ∧ ∀ sealed item,
      ConcreteRepresented s sealed item → ConcreteRepresented state sealed item)
    ⟨ready, fun _ _ present => present⟩ ?_ ?_ trace
  · intro next normalized j r prepared
    cases normalized with
    | none => rw [prepareTrusted_none prepared]; exact ⟨ready, fun _ _ present => present⟩
    | some normalized =>
      obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys canonical read
      subst normalized
      exact ⟨admitted_inner_ready ready allowed reduced,
        fun _ _ present => admitted_inner_representation ready.1 allowed reduced present⟩
  · intro previous next valid frame
    exact ⟨queue_frame_ready (activity_frame_queue frame) valid.1,
      fun sealed item present => (concrete_representation_frame (activity_frame_work frame)).mp
        (valid.2 sealed item present)⟩

theorem resident_input_ledger_absent {s e t : Term} {key : ByteArray} {observations : List Term}
    (canonical : BinaryKeys e) (allowed : Command.inputEventAllowed e = true)
    (checked : IdentityCheckAvoids e key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (trace : ResidentTrace (runTrusted s e observations) (.tuple [a "done", t])) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  apply resident_execution_preserves
    (P := fun state => IdentityAbsent (state.get (a "input_dedupe")) (.binary key)) absent ?_ ?_ trace
  · intro next normalized j r prepared
    cases normalized with
    | none => rw [prepareTrusted_none prepared]; exact absent
    | some normalized =>
      obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys canonical read
      subst normalized
      obtain ⟨groups, before, after, guard, different⟩ := checked
      exact admitted_inner_checked_ledger_absent allowed guard different absent reduced
  · intro previous next valid frame
    rw [frame "input_dedupe" (by decide) (by decide)]
    exact valid

inductive ResidentBatch : Term → List Term → Term → Prop where
  | nil (state : Term) : ResidentBatch state [] state
  | cons {state next final event : Term} {events observations : List Term}
      (head : ResidentTrace (runTrusted state event observations) (.tuple [a "done", next]))
      (tail : ResidentBatch next events final) : ResidentBatch state (event :: events) final

theorem resident_batch_input_safety {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (ready : QueueReady s)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) :
    QueueReady t ∧ ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  induction execution with
  | nil => exact ⟨ready, fun _ _ present => present⟩
  | cons head tail ih =>
    have first := resident_input_safety ready (canonical _ List.mem_cons_self) (allowed _ List.mem_cons_self) head
    have rest := ih first.1 (fun e mem => canonical e (List.mem_cons_of_mem _ mem))
      (fun e mem => allowed e (List.mem_cons_of_mem _ mem))
    exact ⟨rest.1, fun sealed item present => rest.2 sealed item (first.2 sealed item present)⟩

theorem resident_batch_input_ledger_absent {s t : Term} {events : List Term} {key : ByteArray}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ events, IdentityCheckAvoids event key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key)) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  induction execution with
  | nil => exact absent
  | cons head tail ih =>
    have first := resident_input_ledger_absent (canonical _ List.mem_cons_self)
      (allowed _ List.mem_cons_self) (checked _ List.mem_cons_self) absent head
    exact ih (fun e mem => canonical e (List.mem_cons_of_mem _ mem))
      (fun e mem => allowed e (List.mem_cons_of_mem _ mem))
      (fun e mem => checked e (List.mem_cons_of_mem _ mem)) first

theorem resident_input_command_safety {s args result : Term} {j r : List Term}
    (ready : QueueReady s)
    (h : Command.input s args j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch, InputStart result batch ∧
      ∀ t, ResidentBatch s batch t → QueueReady t ∧
        ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  rcases input_start h with duplicate | saturated | invalid | ⟨batch, start, keys, allowed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · exact Or.inr (Or.inr (Or.inr ⟨batch, start, fun _ execution =>
      resident_batch_input_safety execution ready keys (List.all_eq_true.mp allowed)⟩))

theorem checked_prefix_resident_absent {s t main : Term} {earlier selected : List Term} {key : ByteArray}
    {mainGroups : List (List Term)} {j r before after : List Term}
    (checked : Command.inputIdentitiesDistinct (earlier ++ [main]) j = .ok (true, r))
    (mainRead : Command.inputIdentityGroups main before = .ok (mainGroups, after))
    (member : Term.binary key ∈ mainGroups.flatten)
    (canonical : ∀ event ∈ earlier, BinaryKeys event)
    (allowed : ∀ event ∈ earlier, Command.inputEventAllowed event = true)
    (selectedFrom : ∀ event ∈ selected, event ∈ earlier)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (execution : ResidentBatch s selected t) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  have avoids := identity_guard_prefix_avoids checked mainRead member
  exact resident_batch_input_ledger_absent execution
    (fun event present => canonical event (selectedFrom event present))
    (fun event present => allowed event (selectedFrom event present))
    (fun event present => avoids event (selectedFrom event present)) absent

end VerifiedKernel.Session.WorkConservation
