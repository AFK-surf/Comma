import VerifiedKernel.Session.Query.Materialize
import VerifiedKernelProofs.Session.AppendOnly
import VerifiedKernelProofs.Session.DurableConfirmation

/-! Conservation of accepted input at the queue-to-record boundary.
Queue acknowledgments retire materialized input, not completed user work.
The selection proof uses the executable planner, including selective async consumes. -/

namespace VerifiedKernel.Session.WorkConservation
open Data StateQuery

set_option maxHeartbeats 2000000
set_option Elab.async false

theorem take_prefix (xs : List Term) (limit : Int) : takeUpTo xs limit <+: xs := by
  unfold takeUpTo
  split
  · exact List.nil_prefix
  · exact List.take_prefix _ _

theorem split_loop_partition {f : Term → KernelM Bool} {xs acc leading deferred : List Term}
    {j r : List Term} (h : splitWhileLoop f acc xs j = .ok ((leading, deferred), r)) :
    leading ++ deferred = acc.reverse ++ xs := by
  induction xs generalizing acc j r leading deferred with
  | nil =>
    have eq := pure_ok h
    cases eq
    rfl
  | cons x xs ih =>
    unfold splitWhileLoop at h
    obtain ⟨test, j', _, h⟩ := bind_ok h
    cases test with
    | false =>
      have eq := pure_ok h
      cases eq
      rfl
    | true =>
      simpa [List.reverse_cons, List.append_assoc] using ih h

theorem split_partition {f : Term → KernelM Bool} {xs leading deferred : List Term}
    {j r : List Term} (h : splitWhile f xs j = .ok ((leading, deferred), r)) :
    leading ++ deferred = xs := by
  simpa [splitWhile] using split_loop_partition h

theorem matching_loop_subset {f : Term → KernelM Bool} {xs acc selected : List Term} {limit : Nat}
    {j r : List Term} (h : takeMatchingLoop f acc xs limit j = .ok (selected, r)) :
    selected ⊆ acc ++ xs := by
  induction xs generalizing acc j r selected limit with
  | nil =>
    have eq := pure_ok h
    subst selected
    simp
  | cons x xs ih =>
    cases limit with
    | zero =>
      have eq := pure_ok h
      subst selected
      intro v hv
      exact List.mem_append_left _ (List.mem_reverse.mp hv)
    | succ n =>
      unfold takeMatchingLoop at h
      obtain ⟨test, j', _, h⟩ := bind_ok h
      cases test with
      | false =>
        intro v hv
        have hm := ih h hv
        simp only [List.mem_append, List.mem_cons] at hm ⊢
        exact hm.elim Or.inl (fun h => Or.inr (Or.inr h))
      | true =>
        intro v hv
        have hm := ih h hv
        simp only [List.mem_append, List.mem_cons] at hm ⊢
        rcases hm with (hx | ha) | hs
        · exact Or.inr (Or.inl hx)
        · exact Or.inl ha
        · exact Or.inr (Or.inr hs)

theorem matching_subset {f : Term → KernelM Bool} {xs selected : List Term} {limit : Nat}
    {j r : List Term} (h : takeMatching f xs limit j = .ok (selected, r)) :
    selected ⊆ xs := by
  simpa [takeMatching] using matching_loop_subset h

/-- An ACK covers a selected prefix. Every selective consume is also selected. -/
def Plan (items selected : List Term) (ack : Term) (consumes : List Term) : Prop :=
  ∃ pre, pre <+: items ∧ pre ⊆ selected ∧
    ack = pre.getLast?.getD nil ∧ consumes ⊆ selected ∧ selected ⊆ items

theorem take_eq (xs : List Term) (limit : Int) : takeUpTo xs limit = xs.take limit.toNat := by
  unfold takeUpTo
  split
  · have z : limit.toNat = 0 := by omega
    simp [z]
  · rfl

theorem batch_plan {state : Term} {items selected consumes : List Term} {ack : Term} {limit : Int}
    {j r : List Term}
    (h : materializeBatch state items limit j = .ok ((selected, ack, consumes), r)) :
    Plan items selected ack consumes := by
  unfold materializeBatch at h
  obtain ⟨sources, j', _, h⟩ := bind_ok h
  cases active : sources.isEmpty <;> simp only [active, Bool.not_true, Bool.not_false,
    Bool.false_eq_true, ↓reduceIte] at h
  · obtain ⟨⟨leading, deferred⟩, j'', hs, h⟩ := bind_ok h
    have partition := split_partition hs
    obtain ⟨wait, j''', _, h⟩ := bind_ok h
    obtain ⟨taken, j'''', ht, h⟩ := bind_ok h
    have eq := pure_ok h
    cases eq
    refine ⟨takeUpTo leading limit, ?_, ?_, rfl, ?_, ?_⟩
    · exact (take_prefix leading limit).trans ⟨deferred, partition⟩
    · exact List.subset_append_left _ _
    · exact List.subset_append_right _ _
    · intro item member
      rcases List.mem_append.mp member with hp | hc
      · rw [← partition]
        exact List.mem_append_left _ ((take_prefix leading limit).subset hp)
      · rw [← partition]
        exact List.mem_append_right _ (matching_subset ht hc)
  · obtain ⟨⟨leading, deferred⟩, j'', hs, h⟩ := bind_ok h
    have partition := split_partition hs
    have eq := pure_ok h
    cases eq
    have pre : takeUpTo (takeUpTo leading limit ++ takeUpTo deferred 1) limit <+: items := by
      have initial : takeUpTo leading limit ++ takeUpTo deferred 1 <+: takeUpTo items limit := by
        have len : leading.length ≤ limit.toNat := by
          have eq := congrArg List.length partition
          rw [take_eq] at eq
          simp only [List.length_append, List.length_take] at eq
          omega
        rw [take_eq leading, List.take_of_length_le len]
        obtain ⟨tail, ht⟩ := take_prefix deferred 1
        exact ⟨tail, by simpa only [List.append_assoc, ht] using partition⟩
      exact (take_prefix _ limit).trans (initial.trans (take_prefix items limit))
    exact ⟨_, pre, List.Subset.refl _, rfl, by simp, pre.subset⟩

def queueId (item : Term) : Int :=
  integerValue ((item.get (b "queue_id")).default (item.get (a "queue_id")))

def Ordered (items : List Term) : Prop := items.Pairwise (fun x y => queueId x < queueId y)

theorem ordered_identity {items : List Term} (ordered : Ordered items)
    {x y : Term} (hx : x ∈ items) (hy : y ∈ items) (same : queueId x = queueId y) : x = y := by
  induction items with
  | nil => simp at hx
  | cons head tail ih =>
    obtain ⟨before, rest⟩ := List.pairwise_cons.mp ordered
    rcases List.mem_cons.mp hx with xhead | xtail
    · rcases List.mem_cons.mp hy with yhead | ytail
      · exact xhead.trans yhead.symm
      · have := before _ ytail; rw [xhead] at same; omega
    · rcases List.mem_cons.mp hy with yhead | ytail
      · have := before _ xtail; rw [yhead] at same; omega
      · exact ih rest xtail ytail

/-- These are precisely the two queue retirement coordinates in a materialization batch. -/
def Retired (ack : Term) (consumes : List Term) (item : Term) : Prop :=
  (ack ≠ nil ∧ queueId item ≤ queueId ack) ∨
    ∃ consumed ∈ consumes, queueId item = queueId consumed

theorem retired_selected {items selected consumes : List Term} {ack item : Term}
    (plan : Plan items selected ack consumes) (ordered : Ordered items)
    (member : item ∈ items) (retired : Retired ack consumes item) : item ∈ selected := by
  obtain ⟨pre, ⟨post, partition⟩, selectedPre, ackEq, selectedConsumes, selectedItems⟩ := plan
  rcases retired with ⟨present, below⟩ | ⟨consumed, hc, same⟩
  · have ackMember : ack ∈ pre := by
      cases last : pre.getLast? with
      | none => simp [last] at ackEq; exact (present ackEq).elim
      | some value =>
        simp only [last, Option.getD_some] at ackEq
        subst ack
        exact List.mem_of_getLast? last
    rw [← partition] at member ordered
    rcases List.mem_append.mp member with hp | hs
    · exact selectedPre hp
    · have cross := (List.pairwise_append.mp ordered).2.2 ack ackMember item hs
      omega
  · have eq := ordered_identity ordered member (selectedItems (selectedConsumes hc)) same
    rw [eq]
    exact selectedConsumes hc

/-- No canonical queue item is retired without selection by the executable planner. -/
theorem materialize_retirement_safe {state ack item : Term} {items selected consumes : List Term}
    {limit : Int} {j r : List Term}
    (h : materializeBatch state items limit j = .ok ((selected, ack, consumes), r))
    (ordered : Ordered items) (member : item ∈ items) (retired : Retired ack consumes item) :
    item ∈ selected := retired_selected (batch_plan h) ordered member retired

/-- An event came from the runtime encoder for this exact queued item. -/
def Generated (session item event : Term) : Prop :=
  ∃ nextId hwm nextId' hwm' j r,
    queueItemEvent session item nextId hwm j = .ok ((event, nextId', hwm'), r)

theorem materialize_items_cover {session : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool} {j r : List Term}
    (h : materializeItems session items initial j = .ok (final, r)) :
    initial.1 ⊆ final.1 ∧ ∀ item ∈ items, ∃ event ∈ final.1, Generated session item event := by
  induction items generalizing initial j r with
  | nil =>
    have eq := pure_ok h
    subst final
    exact ⟨List.Subset.refl _, by simp⟩
  | cons item items ih =>
    unfold materializeItems at h
    rw [List.foldlM_cons] at h
    obtain ⟨next, j', first, rest⟩ := bind_ok h
    obtain ⟨⟨event, nextId, hwm⟩, j'', generated, first⟩ := bind_ok first
    obtain ⟨wake, j''', _, first⟩ := bind_ok first
    have eq := pure_ok first
    subst next
    obtain ⟨kept, covers⟩ := ih rest
    refine ⟨fun _ member => kept (List.mem_cons_of_mem _ member), ?_⟩
    intro x member
    rcases List.mem_cons.mp member with rfl | member
    · exact ⟨event, kept (List.mem_cons_self), _, _, _, _, _, _, generated⟩
    · exact covers x member

/-- The actual planner and encoder jointly cover every retired item. -/
theorem retirement_has_record {state session ack item : Term}
    {items selected consumes : List Term} {limit : Int} {j r j' r' : List Term}
    {initial final : List Term × Term × Term × Bool}
    (plan : materializeBatch state items limit j = .ok ((selected, ack, consumes), r))
    (encoded : materializeItems session selected initial j' = .ok (final, r'))
    (ordered : Ordered items) (member : item ∈ items) (retired : Retired ack consumes item) :
    ∃ event ∈ final.1.reverse, Generated session item event := by
  obtain ⟨event, he, generated⟩ := (materialize_items_cover encoded).2 item
    (materialize_retirement_safe plan ordered member retired)
  exact ⟨event, List.mem_reverse.mpr he, generated⟩

/-- The public query returns the generated records in the same batch as queue retirement. -/
theorem materialize_batch_has_records {state result : Term} {limit : Int} {j r : List Term}
    (h : materialize state limit j = .ok (result, r)) :
    ∃ session items selected ack consumes events wake hwm j₁ j₂ j₃,
      unackedItems state j₁ = .ok (items, j₂) ∧
      materializeBatch state items limit j₂ = .ok ((selected, ack, consumes), j₃) ∧
      result = .tuple [list events, Term.bool wake, hwm] ∧
      (Ordered items → ∀ item ∈ items, Retired ack consumes item →
        ∃ event ∈ events, Generated session item event) ∧
      field state "session_id" j = .ok (session, j₁) := by
  unfold materialize at h
  obtain ⟨session, j₁, sid, h⟩ := bind_ok h
  obtain ⟨items, j₂, pending, h⟩ := bind_ok h
  obtain ⟨⟨selected, ack, consumes⟩, j₃, plan, h⟩ := bind_ok h
  obtain ⟨nextId, j₄, _, h⟩ := bind_ok h
  obtain ⟨⟨events, nextId', hwm, wake⟩, j₅, encoded, h⟩ := bind_ok h
  dsimp only at h
  split at h
  · obtain ⟨acks, j₆, _, h⟩ := bind_ok h
    obtain ⟨consumed, j₇, _, h⟩ := bind_ok h
    obtain ⟨retries, j₈, _, h⟩ := bind_ok h
    have eq := pure_ok h
    refine ⟨session, items, selected, ack, consumes, _, _, _, j₁, j₂, j₃,
      pending, plan, eq, ?_, sid⟩
    intro ordered item member retired
    obtain ⟨event, he, generated⟩ := retirement_has_record plan encoded ordered member retired
    exact ⟨event, List.mem_append_left _ (List.mem_append_left _ (List.mem_append_left _ he)), generated⟩
  · obtain ⟨ackId, j₆, _, h⟩ := bind_ok h
    obtain ⟨acks, j₇, _, h⟩ := bind_ok h
    obtain ⟨consumed, j₈, _, h⟩ := bind_ok h
    obtain ⟨retries, j₉, _, h⟩ := bind_ok h
    have eq := pure_ok h
    refine ⟨session, items, selected, ack, consumes, _, _, _, j₁, j₂, j₃,
      pending, plan, eq, ?_, sid⟩
    intro ordered item member retired
    obtain ⟨event, he, generated⟩ := retirement_has_record plan encoded ordered member retired
    exact ⟨event, List.mem_append_left _ (List.mem_append_left _ (List.mem_append_left _ he)), generated⟩

end VerifiedKernel.Session.WorkConservation
