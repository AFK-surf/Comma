import VerifiedKernelProofs.Session.WorkConservation
import VerifiedKernelProofs.Session.WorkFrames

/-! A proof-only projection of the existing working revision and durable baseline.
Items are ghost witnesses for queued payloads and their generated Session records.
They are not a new runtime ledger, identity, acceptance gate, or storage format.

The host must commit the complete event batch by CAS, restore the committed
snapshot on restart, and seal archive records before it removes the live prefix.
These external effects remain runtime assumptions, not Lean storage proofs. -/

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

structure Snapshot where
  queued : List Term := []
  recorded : List Term := []
  archived : List Term := []

def Represented (s : Snapshot) (item : Term) : Prop :=
  item ∈ s.queued ∨ item ∈ s.recorded ∨ item ∈ s.archived

def Preserves (s t : Snapshot) : Prop := ∀ item, Represented s item → Represented t item

noncomputable def transfer (s : Snapshot) (selected : List Term) (ack : Term)
    (consumes : List Term) : Snapshot := by
  classical
  exact { s with queued := s.queued.filter (fun item => decide (¬Retired ack consumes item))
                 recorded := s.recorded ++ selected }

/-- Queue transfer preserves representation when the executable planner covers every removal. -/
theorem transfer_preserves (s : Snapshot) {state ack : Term} {selected consumes : List Term}
    {limit : Int} {j r : List Term}
    (plan : materializeBatch state s.queued limit j = .ok ((selected, ack, consumes), r))
    (ordered : Ordered s.queued) : Preserves s (transfer s selected ack consumes) := by
  classical
  intro item represented
  rcases represented with queued | recorded | archived
  · by_cases retired : Retired ack consumes item
    · exact Or.inr (Or.inl (List.mem_append_right _
        (materialize_retirement_safe plan ordered queued retired)))
    · exact Or.inl (List.mem_filter.mpr ⟨queued, by simp [retired]⟩)
  · exact Or.inr (Or.inl (List.mem_append_left _ recorded))
  · exact Or.inr (Or.inr archived)

/-- Stage transitions use the existing queue planner. A failed encoder produces no transition. -/
inductive SnapshotStep : Snapshot → Snapshot → Prop where
  | enqueue (s : Snapshot) (item : Term) :
      SnapshotStep s { s with queued := s.queued ++ [item] }
  | materialize (s : Snapshot) (state session ack : Term) (selected consumes : List Term)
      (limit : Int) (j r j' r' : List Term) (initial final : List Term × Term × Term × Bool)
      (plan : materializeBatch state s.queued limit j = .ok ((selected, ack, consumes), r))
      (ordered : Ordered s.queued)
      (encoded : materializeItems session selected initial j' = .ok (final, r')) :
      SnapshotStep s (transfer s selected ack consumes)
  | compact (s : Snapshot) : SnapshotStep s s
  | archive (s : Snapshot) (sealed tail : List Term) (partition : s.recorded = sealed ++ tail) :
      SnapshotStep s { s with recorded := tail, archived := s.archived ++ sealed }

theorem snapshot_step_preserves {s t : Snapshot} (step : SnapshotStep s t) : Preserves s t := by
  cases step with
  | enqueue item =>
    intro x represented
    rcases represented with queued | recorded | archived
    · exact Or.inl (List.mem_append_left _ queued)
    · exact Or.inr (Or.inl recorded)
    · exact Or.inr (Or.inr archived)
  | materialize state session ack selected consumes limit j r j' r' initial final plan ordered encoded =>
    exact transfer_preserves s plan ordered
  | compact => exact fun _ h => h
  | archive sealed tail partition =>
    intro item represented
    rcases represented with queued | recorded | archived
    · exact Or.inl queued
    · rw [partition] at recorded
      rcases List.mem_append.mp recorded with sealed | live
      · exact Or.inr (Or.inr (List.mem_append_right _ sealed))
      · exact Or.inr (Or.inl live)
    · exact Or.inr (Or.inr (List.mem_append_left _ archived))

structure Revision where
  durable : Snapshot := {}
  working : Snapshot := {}
  staged : List Term := []
  confirmable : List Term := []
  accepted : List Term := []

/-- `staged` and `confirmable` name protocol evidence, not additional product state. -/
def Safe (s : Revision) : Prop :=
  (∀ item ∈ s.accepted, Represented s.durable item) ∧
  Preserves s.durable s.working ∧
  (∀ item ∈ s.staged, Represented s.working item) ∧
  (∀ item ∈ s.confirmable, Represented s.durable item)

inductive Step : Revision → Revision → Prop where
  | input (s : Revision) (item : Term) :
      Step s { s with
        working := { s.working with queued := s.working.queued ++ [item] }
        staged := s.staged ++ [item] }
  | stage (s : Revision) (next : Snapshot) (change : SnapshotStep s.working next) :
      Step s { s with working := next }
  | fence (s : Revision) :
      Step s { s with durable := s.working, staged := [], confirmable := s.confirmable ++ s.staged }
  | notify (s : Revision) (item : Term) (ready : item ∈ s.confirmable) :
      Step s { s with accepted := s.accepted ++ [item] }
  | restart (s : Revision) :
      Step s { s with working := s.durable, staged := [], confirmable := [] }
  | failedFence (s : Revision) :
      Step s { s with working := s.durable, staged := [] }
  | staleResult (s : Revision) : Step s s

theorem initial_safe : Safe {} := by simp [Safe, Preserves, Represented]

theorem step_safe {s t : Revision} (safe : Safe s) (step : Step s t) : Safe t := by
  obtain ⟨accepted, working, staged, confirmable⟩ := safe
  cases step with
  | input item =>
    have kept := snapshot_step_preserves (SnapshotStep.enqueue s.working item)
    refine ⟨accepted, fun x h => kept x (working x h), ?_, confirmable⟩
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact kept x (staged x old)
    · have eq : x = item := by simpa using new
      subst x
      exact Or.inl (List.mem_append_right _ (List.mem_cons_self))
  | stage next change =>
    have kept := snapshot_step_preserves change
    exact ⟨accepted, fun x h => kept x (working x h), fun x h => kept x (staged x h), confirmable⟩
  | fence =>
    refine ⟨fun x h => working x (accepted x h), fun _ h => h, by simp, ?_⟩
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact working x (confirmable x old)
    · exact staged x new
  | notify item ready =>
    refine ⟨?_, working, staged, confirmable⟩
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact accepted x old
    · have eq : x = item := by simpa using new
      subst x
      exact confirmable item ready
  | restart => exact ⟨accepted, fun _ h => h, by simp, by simp⟩
  | failedFence => exact ⟨accepted, fun _ h => h, by simp, confirmable⟩
  | staleResult => exact ⟨accepted, working, staged, confirmable⟩

inductive Reachable : Revision → Prop where
  | initial : Reachable {}
  | next (reachable : Reachable s) (step : Step s t) : Reachable t

theorem reachable_safe {s : Revision} (reachable : Reachable s) : Safe s := by
  induction reachable with
  | initial => exact initial_safe
  | next _ step ih => exact step_safe ih step

/-- All finite traces retain each accepted input in durable queued, recorded, or sealed facts. -/
theorem accepted_work_conserved {s : Revision} (reachable : Reachable s) :
    ∀ item ∈ s.accepted, Represented s.durable item := (reachable_safe reachable).1

/-- Confirmation candidates come from the committed batch, never only the working revision. -/
theorem confirmation_has_durable_fact {s : Revision} (reachable : Reachable s)
    {item : Term} (ready : item ∈ s.confirmable) : Represented s.durable item :=
  (reachable_safe reachable).2.2.2 item ready

/-- An in-memory input cannot justify acceptance when its durable snapshot is empty. -/
theorem premature_acceptance_unsafe (item : Term) :
    ¬Safe { working := { queued := [item] }, accepted := [item] } := by
  simp [Safe, Represented]

/-- Keeping a dedupe receipt alone cannot replace the pending or recorded input. -/
theorem receipt_without_work_unsafe (item : Term) :
    ¬Safe { accepted := [item] } := by
  simp [Safe, Represented]

end VerifiedKernel.Session.WorkConservation
