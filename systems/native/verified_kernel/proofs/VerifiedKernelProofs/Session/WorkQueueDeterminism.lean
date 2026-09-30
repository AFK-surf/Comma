import VerifiedKernelProofs.Session.WorkMaterializeFrame

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem queue_id_injective {items : List Term} {left right : Term}
    (unique : (items.map queueId).Nodup) (one : left ∈ items) (two : right ∈ items)
    (same : queueId left = queueId right) : left = right := by
  induction items with
  | nil => simp at one
  | cons item items ih =>
    simp only [List.map_cons, List.nodup_cons] at unique
    rcases List.mem_cons.mp one with rfl | leftMember
    · rcases List.mem_cons.mp two with rfl | rightMember
      · rfl
      · exact (unique.1 (same ▸ List.mem_map_of_mem rightMember)).elim
    · rcases List.mem_cons.mp two with rfl | rightMember
      · exact (unique.1 (same ▸ List.mem_map_of_mem leftMember)).elim
      · exact ih unique.2 leftMember rightMember

theorem normalize_queue_ordered {items output j r : List Term}
    (call : normalizeQueue (list items) j = .ok (output, r)) : KeyOrdered queueId output := by
  unfold normalizeQueue at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  exact queue_sort_ordered call

theorem normalize_queue_same_results {items left right j r before after : List Term}
    (canonical : ∀ item ∈ items, CanonicalQueueItem item)
    (unique : (items.map queueId).Nodup)
    (one : normalizeQueue (list items) j = .ok (left, r))
    (two : normalizeQueue (list items) before = .ok (right, after)) : left = right := by
  have first := normalizeQueue_permutation canonical one
  have second := normalizeQueue_permutation canonical two
  apply List.Perm.eq_of_pairwise _ (normalize_queue_ordered one) (normalize_queue_ordered two) (first.trans second.symm)
  intro a b member other ab ba
  exact queue_id_injective unique (first.mem_iff.mp member) (second.mem_iff.mp other) (Int.le_antisymm ab ba)

theorem deterministic_fetch (state key : Term) : Deterministic (fetch state key) := by
  intro left right j r before after one two
  exact (fetch_ok_iff.mp one).2.2.1.trans (fetch_ok_iff.mp two).2.2.1.symm

theorem deterministic_put (state key value : Term) : Deterministic (put state key value) :=
  fun _ _ _ _ _ _ one two => (put_ok one).trans (put_ok two).symm

theorem deterministic_nonnilPut (state key value : Term) : Deterministic (nonnilPut state key value) := by
  unfold nonnilPut
  split
  · exact deterministic_put _ _ _
  · exact deterministic_pure _

theorem deterministic_setMember (state key : Term) : Deterministic (setMember state key) := by
  unfold setMember
  split
  · exact deterministic_pure _
  · dsimp only
    split
    · exact deterministic_pure _
    · exact deterministic_fail _ _

theorem deterministic_dedupeHit (state : Term) (keys : List Term) : Deterministic (dedupeHit state keys) := by
  induction keys with
  | nil => exact deterministic_pure _
  | cons key keys ih =>
    unfold dedupeHit
    apply deterministic_bind (deterministic_setMember _ _)
    intro found
    split
    · exact deterministic_pure _
    · exact ih

theorem deterministic_setPut (state key : Term) : Deterministic (setPut state key) := by
  unfold setPut
  split
  · exact deterministic_pure _
  · dsimp only
    split
    · exact deterministic_pure _
    · exact deterministic_fail _ _

theorem deterministic_addDedupe (state : Term) (keys : List Term) : Deterministic (addDedupe state keys) := by
  intro left right j r before after one two
  exact foldlM_same_results (first := setPut) (second := setPut)
    (fun state key => deterministic_setPut state key) one two

theorem deterministic_write (state : Term) (values : List (String × Term)) : Deterministic (Data.write state values) := by
  induction values generalizing state with
  | nil => exact deterministic_pure _
  | cons value values ih =>
    unfold Data.write
    rw [List.foldlM_cons]
    apply deterministic_bind
    · apply deterministic_bind (deterministic_fetch _ _)
      intro _
      exact deterministic_put _ _ _
    · intro next
      exact ih next

macro "queue_same_step" one:ident two:ident : tactic => `(tactic| (
  obtain ⟨value, _, first, tailOne⟩ := bind_ok $one
  obtain ⟨other, _, second, tailTwo⟩ := bind_ok $two
  clear $one $two
  have $one := tailOne
  have $two := tailTwo
  have same : value = other := by
    first
    | exact Subsingleton.elim _ _
    | exact deterministic_access _ _ _ _ _ _ _ _ first second
    | exact deterministic_fetch _ _ _ _ _ _ _ _ first second
    | exact stringify_same_results first second
    | exact deterministic_queueKeys _ _ _ _ _ _ _ _ _ first second
    | exact deterministic_nonnilPut _ _ _ _ _ _ _ _ _ first second
    | exact deterministic_dedupeHit _ _ _ _ _ _ _ _ first second
    | exact deterministic_addDedupe _ _ _ _ _ _ _ _ first second
  subst other
  try (have read := field_value first; subst value)
))

/-- Replaying a queue append has one reducer result. Clock observations affect only later activity fields. -/
theorem queue_append_same_results {state event left right : Term} {j r before after : List Term}
    (ready : QueueAllocated state)
    (one : queueAppend state event j = .ok (left, r))
    (two : queueAppend state event before = .ok (right, after)) : left = right := by
  obtain ⟨items, next, queueRead, nextRead, _, canonical, _, unique⟩ := ready
  unfold queueAppend at one two
  by_cases missingKind : (!event.has (b "kind")) = true
  · simp only [missingKind, ↓reduceIte] at one
    obtain ⟨_, _, failed, _⟩ := bind_ok one
    exact (fail_ok failed).elim
  · simp only [missingKind, ↓reduceIte] at one two
    iterate 7 queue_same_step one two
    obtain ⟨hit, _, firstHit, one⟩ := bind_ok one
    obtain ⟨other, _, secondHit, two⟩ := bind_ok two
    have same := deterministic_dedupeHit _ _ _ _ _ _ _ _ firstHit secondHit
    subst other
    cases hit with
    | true => exact (pure_ok one).trans (pure_ok two).symm
    | false =>
      queue_same_step one two
      simp only [nextRead, default_integer] at one two
      iterate 6 queue_same_step one two
      simp only [queueRead] at one two
      obtain ⟨normalized, _, firstQueue, one⟩ := bind_ok one
      obtain ⟨other, _, secondQueue, two⟩ := bind_ok two
      have same := normalize_queue_same_results canonical unique firstQueue secondQueue
      subst other
      queue_same_step one two
      simp only [nextRead, default_integer] at one two
      obtain ⟨added, _, firstAdd, one⟩ := bind_ok one
      obtain ⟨other, _, secondAdd, two⟩ := bind_ok two
      simp only [add_integer] at firstAdd secondAdd
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj firstAdd)
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj secondAdd)
      obtain ⟨maximumValue, _, firstMax, one⟩ := bind_ok one
      obtain ⟨other, _, secondMax, two⟩ := bind_ok two
      simp only [maximum_integer] at firstMax secondMax
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj firstMax)
      obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Except.ok.inj secondMax)
      iterate 3 queue_same_step one two
      exact deterministic_write _ _ _ _ _ _ _ _ one two

end VerifiedKernel.Session.WorkConservation
