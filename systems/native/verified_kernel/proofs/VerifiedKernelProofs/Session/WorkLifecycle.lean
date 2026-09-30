import VerifiedKernelProofs.Session.WorkReady
import VerifiedKernel.Session.Lifecycle

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxRecDepth 4096
set_option maxHeartbeats 4000000

theorem get_present_has {s key : Term} (present : s.get key ≠ nil) : s.has key = true := by
  cases s with
  | map entries =>
    simp only [Term.get] at present
    cases found : entries.find? (fun entry => entry.1 == key) with
    | none => simp [found, nil] at present
    | some pair =>
      have matched := List.find?_some found
      exact List.any_eq_true.mpr ⟨pair, List.mem_of_find?_eq_some found, matched⟩
  | _ => exact (present rfl).elim

theorem fillDefaults_get {s : Term} {key : String} (present : s.get (a key) ≠ nil) :
    (Lifecycle.fillDefaults s).get (a key) = s.get (a key) := by
  have folded : ∀ (entries : List (String × Term)) (state : Term), state.get (a key) ≠ nil →
      (entries.foldl (fun current pair => if current.has (a pair.1) then current else current.put (a pair.1) pair.2) state).get (a key) =
        state.get (a key) := by
    intro entries
    induction entries with
    | nil => intro state _; rfl
    | cons pair rest ih =>
      intro state present
      rw [List.foldl_cons]
      split
      · exact ih state present
      · rename_i absent
        have different : pair.1 ≠ key := by
          intro same
          rw [same] at absent
          exact absent (get_present_has present)
        have same := get_put_other state pair.2 different
        exact (ih _ (by rw [same]; exact present)).trans same
  exact folded Lifecycle.defaults s present

theorem fillDefaults_ready {s : Term} (ready : QueueReady s) : QueueReady (Lifecycle.fillDefaults s) := by
  obtain ⟨⟨items, next, read, nextRead, positive, canonical, bounded, unique⟩,
    ⟨original, ack, originalRead, baseline, above⟩, bound⟩ := ready
  have queue := fillDefaults_get (key := "input_queue") (s := s) (by rw [read]; intro h; cases h)
  have allocator := fillDefaults_get (key := "next_queue_id") (s := s) (by rw [nextRead]; intro h; cases h)
  have watermark := fillDefaults_get (key := "queue_ack_id") (s := s) (by rw [baseline]; intro h; cases h)
  exact ⟨⟨items, next, queue.trans read, allocator.trans nextRead, positive, canonical, bounded, unique⟩,
    ⟨original, ack, queue.trans originalRead, watermark.trans baseline, above⟩, by simpa only [allocator, watermark] using bound⟩

theorem kmax_integer (left right : Int) (j : List Term) :
    kmax (i left) (i right) j = .ok (i (max left right), j) := by
  simp only [kmax, less, bind, StateT.bind, Except.bind, i, order_integer,
    Pure.pure, StateT.pure, Except.pure]
  cases cmp : compare left right with
  | lt =>
    have le := Int.le_of_lt (Int.compare_eq_lt.mp cmp)
    simp [Int.max_eq_right le, StateT.pure, Pure.pure, Except.pure]
  | eq =>
    have same := Int.compare_eq_eq.mp cmp
    subst right
    simp [StateT.pure, Pure.pure, Except.pure]
  | gt =>
    have le := Int.le_of_lt (Int.compare_eq_gt.mp cmp)
    simp [Int.max_eq_left le, StateT.pure, Pure.pure, Except.pure]

theorem largest_bounded {items : List Term} {fallback bound : Int} {value : Term} {j r : List Term}
    (small : ∀ item ∈ items, ∃ n, item = i n ∧ n < bound) (initial : fallback < bound)
    (h : largest items (i fallback) j = .ok (value, r)) : ∃ n, value = i n ∧ n < bound := by
  have step : ∀ (acc item result : Term) journal rest,
      (∃ n, acc = i n ∧ n < bound) → (∃ n, item = i n ∧ n < bound) →
      (do if ← less item acc then pure acc else pure item) journal = .ok (result, rest) →
      ∃ n, result = i n ∧ n < bound := by
    intro acc item result journal rest before current call
    obtain ⟨_, _, _, call⟩ := bind_ok call
    split at call
    · rw [pure_ok call]; exact before
    · rw [pure_ok call]; exact current
  have folded : ∀ (xs : List Term) acc value journal rest,
      (∀ item ∈ xs, ∃ n, item = i n ∧ n < bound) → (∃ n, acc = i n ∧ n < bound) →
      xs.foldlM (fun acc item => (do if ← less item acc then pure acc else pure item : KernelM Term)) acc journal = .ok (value, rest) →
      ∃ n, value = i n ∧ n < bound := by
    intro xs
    induction xs with
    | nil => intro acc value journal rest _ before call; rw [pure_ok call]; exact before
    | cons item xs ih =>
      intro acc value journal rest small before call
      rw [List.foldlM_cons] at call
      obtain ⟨next, _, first, call⟩ := bind_ok call
      exact ih _ _ _ _ (fun item member => small item (List.mem_cons_of_mem _ member))
        (step _ _ _ _ _ before (small _ List.mem_cons_self) first) call
  cases items with
  | nil => exact ⟨fallback, pure_ok h, initial⟩
  | cons item items =>
    exact folded _ _ _ _ _
      (fun current member => small current (List.mem_cons_of_mem _ member))
      (small _ List.mem_cons_self) h

theorem nextQueueId_stable {items : List Term} {next : Int} {value : Term} {j r : List Term}
    (positive : 0 < next) (bounded : ∀ item ∈ items, queueId item < next)
    (h : Lifecycle.nextQueueId items (i next) j = .ok (value, r)) : value = i next := by
  unfold Lifecycle.nextQueueId at h
  obtain ⟨ids, _, idsRead, h⟩ := bind_ok h
  obtain ⟨highest, _, largestRead, h⟩ := bind_ok h
  have small : ∀ id ∈ ids, ∃ n, id = i n ∧ n < next := by
    intro id member
    obtain ⟨item, present, _, _, read⟩ := mapM_outputs idsRead id member
    exact ⟨queueId item, queueItemId_value read, bounded item present⟩
  obtain ⟨highestValue, highestEq, highestBound⟩ := largest_bounded small positive largestRead
  subst highest
  obtain ⟨increment, _, incrementRead, h⟩ := bind_ok h
  have incrementValue : increment = i (highestValue + 1) := pure_ok incrementRead
  subst increment
  obtain ⟨stored, _, storedRead, h⟩ := bind_ok h
  simp only [i, integerValue, kmax_integer] at storedRead
  have storedValue := (Prod.mk.inj (Except.ok.inj storedRead)).1.symm
  have fixed : max next 1 = next := Int.max_eq_left (by omega)
  rw [fixed] at storedValue
  subst stored
  rw [kmax_integer] at h
  have final := (Prod.mk.inj (Except.ok.inj h)).1.symm
  simpa only [Int.max_eq_right (show highestValue + 1 ≤ next by omega)] using final

theorem prune_predicate {item : Term} {ack : Int} {value : Bool} {j r : List Term}
    (h : (do return !(← atMost (← queueItemId item) (i ack))) j = .ok (value, r)) :
    value = decide (ack < queueId item) := by
  obtain ⟨id, _, read, h⟩ := bind_ok h
  rw [queueItemId_value read] at h
  simp only [atMost, i, order_integer, Bind.bind, StateT.bind, Except.bind,
    Pure.pure, StateT.pure, Except.pure] at h
  have result := (Prod.mk.inj (Except.ok.inj h)).1.symm
  by_cases below : ack < queueId item
  · simp [Int.compare_eq_gt.mpr below, below] at result ⊢
    exact result
  · have notGreater : compare (queueId item) ack ≠ .gt := fun same => below (Int.compare_eq_gt.mp same)
    cases comparison : compare (queueId item) ack with
    | lt =>
      rw [comparison] at result
      change value = false at result
      simpa [below] using result
    | eq =>
      rw [comparison] at result
      change value = false at result
      simpa [below] using result
    | gt => exact (notGreater comparison).elim

theorem pruneQueue_permutation {items kept : List Term} {ack : Int} {j r : List Term}
    (canonical : ∀ item ∈ items, CanonicalQueueItem item) (above : ∀ item ∈ items, ack < queueId item)
    (h : Lifecycle.pruneQueue (list items) (i ack) j = .ok (kept, r)) : kept.Perm items := by
  unfold Lifecycle.pruneQueue at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  have permutation := normalizeQueue_permutation canonical normalizedRead
  have exactFilter := filterM_exact (fun _ _ _ _ read => prune_predicate read) h
  have unchanged : normalized.filter (fun item => decide (ack < queueId item)) = normalized := by
    apply List.filter_eq_self.mpr
    intro item member
    exact decide_eq_true (above item (permutation.mem_iff.mp member))
  rw [exactFilter, unchanged]
  exact permutation

/-- Reload normalization preserves the ready queue and the original live records. -/
theorem normalize_work {s t : Term} {j r : List Term}
    (ready : QueueReady s) (h : Lifecycle.normalize s j = .ok (t, r)) :
    QueueReady t ∧
      (∃ original kept, s.get (a "input_queue") = list original ∧
        t.get (a "input_queue") = list kept ∧ kept.Perm original) ∧
      t.get (a "messages") = ((Lifecycle.fillDefaults s).get (a "messages")).default (list []) := by
  have filledReady := fillDefaults_ready ready
  obtain ⟨⟨items, next, read, nextRead, positive, canonical, bounded, unique⟩,
    ⟨original, ack, originalRead, baseline, above⟩, bound⟩ := filledReady
  have equal : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  have sourceRead : s.get (a "input_queue") = list items := by
    obtain ⟨queue, _, before, _⟩ := ready.1
    have frame := fillDefaults_get (key := "input_queue") (s := s) (by rw [before]; intro h; cases h)
    exact frame.symm.trans read
  unfold Lifecycle.normalize at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨oldAck, _, ackRead, h⟩ := bind_ok h
  have ackValue := (field_value ackRead).trans baseline
  subst oldAck
  obtain ⟨queue, _, queueRead, h⟩ := bind_ok h
  have queueValue := (field_value queueRead).trans read
  subst queue
  obtain ⟨kept, _, pruned, h⟩ := bind_ok h
  have permutation := pruneQueue_permutation canonical above pruned
  iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨storedNext, _, storedRead, h⟩ := bind_ok h
  have storedValue := (field_value storedRead).trans nextRead
  subst storedNext
  obtain ⟨newNext, _, newRead, h⟩ := bind_ok h
  have fixed := nextQueueId_stable positive
    (fun item member => bounded item (permutation.mem_iff.mp member)) newRead
  subst newNext
  iterate 15 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨messages, _, messagesRead, h⟩ := bind_ok h
  have messagesValue := field_value messagesRead
  subst messages
  repeat
    (fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = .ok (t, r) at h)
     obtain ⟨_, _, _, h⟩ := bind_ok h)
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have queueWritten : normalized.get (a "input_queue") = list kept := by
    iterate 6 obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written rfl).trans (get_put_same _ _ _)
  have ackWritten : normalized.get (a "queue_ack_id") = i ack := by
    iterate 4 obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written rfl).trans (get_put_same _ _ _)
  have nextWritten : normalized.get (a "next_queue_id") = i next := by
    iterate 5 obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written rfl).trans (get_put_same _ _ _)
  have recordsWritten : normalized.get (a "messages") =
      ((Lifecycle.fillDefaults s).get (a "messages")).default (list []) := by
    iterate 18 obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written rfl).trans (get_put_same _ _ _)
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨active, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨providers, _, providersWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  have tailFrame : ∀ key : String, key ≠ "activity_status" → key ≠ "context_provider_states" → key ≠ "input_dedupe" →
      t.get (a key) = normalized.get (a key) := by
    intro key activity providers dedupe
    exact (write_field_frame h (by simp [Ne.symm dedupe])).trans
      ((write_field_frame providersWrite (by simp [Ne.symm providers])).trans
        (write_field_frame activityWrite (by simp [Ne.symm activity])))
  have queueFinal := (tailFrame "input_queue" (by decide) (by decide) (by decide)).trans queueWritten
  have ackFinal := (tailFrame "queue_ack_id" (by decide) (by decide) (by decide)).trans ackWritten
  have nextFinal := (tailFrame "next_queue_id" (by decide) (by decide) (by decide)).trans nextWritten
  refine ⟨⟨⟨kept, next, queueFinal, nextFinal, positive,
    fun item member => canonical item (permutation.mem_iff.mp member),
    fun item member => bounded item (permutation.mem_iff.mp member),
    (permutation.map queueId).nodup_iff.mpr unique⟩,
    ⟨kept, ack, queueFinal, ackFinal, fun item member => above item (permutation.mem_iff.mp member)⟩, ?_⟩,
    ⟨items, kept, sourceRead, queueFinal, permutation⟩,
    (tailFrame "messages" (by decide) (by decide) (by decide)).trans recordsWritten⟩
  simpa only [ackFinal, nextFinal, baseline, nextRead] using bound

theorem normalize_representation {s t item : Term} {sealed j r : List Term}
    (ready : QueueReady s) (h : Lifecycle.normalize s j = .ok (t, r))
    (represented : ConcreteRepresented s sealed item) : ConcreteRepresented t sealed item := by
  obtain ⟨_, ⟨original, kept, read, output, permutation⟩, records⟩ := normalize_work ready h
  rcases represented with queued | recorded | archived
  · obtain ⟨items, current, sourceRead, member, fields⟩ := queued
    have equal : items = original := Term.list.inj (sourceRead.symm.trans read)
    subst items
    exact Or.inl ⟨kept, current, output, permutation.mem_iff.mpr member, fields⟩
  · obtain ⟨record, ⟨messages, sourceRead, member⟩, fields⟩ := recorded
    have frame := fillDefaults_get (key := "messages") (s := s) (by rw [sourceRead]; intro h; cases h)
    rw [frame, sourceRead] at records
    exact Or.inr (Or.inl ⟨record, ⟨messages, records, member⟩, fields⟩)
  · exact Or.inr (Or.inr archived)

theorem build_get {entries : List (String × Term)} {key : String}
    (absent : entries.all (fun pair => pair.1 != key) = true) :
    (Lifecycle.build entries).get (a key) = Lifecycle.blank.get (a key) := by
  have folded : ∀ (entries : List (String × Term)) (state : Term),
      entries.all (fun pair => pair.1 != key) = true →
      (entries.foldl (fun current pair => current.put (a pair.1) pair.2) state).get (a key) = state.get (a key) := by
    intro entries
    induction entries with
    | nil => intro state _; rfl
    | cons pair rest ih =>
      intro state absent
      simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne] at absent
      rw [List.foldl_cons, ih _ absent.2, get_put_other _ _ absent.1]
  exact folded entries Lifecycle.blank absent

theorem build_ready {entries : List (String × Term)}
    (queue : entries.all (fun pair => pair.1 != "input_queue") = true)
    (next : entries.all (fun pair => pair.1 != "next_queue_id") = true)
    (ack : entries.all (fun pair => pair.1 != "queue_ack_id") = true) : QueueReady (Lifecycle.build entries) := by
  have queueRead : (Lifecycle.build entries).get (a "input_queue") = list [] := (build_get queue).trans rfl
  have nextRead : (Lifecycle.build entries).get (a "next_queue_id") = i 1 := (build_get next).trans rfl
  have ackRead : (Lifecycle.build entries).get (a "queue_ack_id") = i 0 := (build_get ack).trans rfl
  exact ⟨queue_allocated_empty queueRead nextRead, ⟨[], 0, queueRead, ackRead, by simp⟩,
    by rw [ackRead, nextRead]; decide⟩

/-- The actual public constructor establishes queue invariants without a caller-supplied initial state. -/
theorem create_ready {s args t : Term} {j r : List Term}
    (h : Lifecycle.create s args j = .ok (t, r)) : QueueReady t := by
  unfold Lifecycle.create at h
  split at h
  · repeat
      (fail_if_success (head_is h [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (t, r) at h)
       obtain ⟨_, _, _, h⟩ := bind_ok h)
    exact (normalize_work (build_ready rfl rfl rfl) h).1
  · exact (fail_ok h).elim

end VerifiedKernel.Session.WorkConservation
