import VerifiedKernelProofs.Session.WorkEnqueue
import VerifiedKernelProofs.Session.WorkEncoding

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem binary_beq_true {t : Term} {key : String} (h : (t == b key) = true) : t = b key := by
  cases t <;> simp [b, Term.text, BEq.beq] at h
  exact congrArg Term.binary (ByteArray.ext (by
    simpa only [ByteArray.beq, beq_iff_eq, String.toUTF8_eq_toByteArray] using h))

theorem get_put_binary_other (v x : Term) {key other : String} (different : other ≠ key) :
    (v.put (b other) x).get (b key) = v.get (b key) := by
  have neq : (b other == b key) = false := by simp [binary_key_beq, different]
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, neq]
    rw [find?_filter_of_imp]
    intro entry matched
    have same := binary_beq_true matched
    simp [same, binary_key_beq, Ne.symm different]
  | _ => simp [Term.put, Term.get, neq]

theorem binary_map_atom_nil {fields : List (Term × Term)} (key : String)
    (binary : fields.all (fun pair => pair.1.isBinary) = true) :
    (Term.map fields).get (a key) = nil := by
  have absent : fields.find? (fun pair => pair.1 == a key) = none := by
    apply List.find?_eq_none.mpr
    intro pair member
    have typed := List.all_eq_true.mp binary pair member
    cases pair with
    | mk name value => cases name <;> simp [Term.isBinary, BEq.beq, a] at typed ⊢
  simp only [Term.get, absent, Option.map_none, Option.getD_none, nil, a]

theorem get_put_binary_atom (item value : Term) (binary atom : String) :
    (item.put (b binary) value).get (a atom) = item.get (a atom) := by
  cases item with
  | map fields =>
    simp only [Term.put, Term.get, List.find?_cons]
    simp only [show (b binary == a atom) = false from rfl, Bool.false_eq_true, ↓reduceIte]
    rw [find?_filter_of_imp]
    intro entry matched
    have same := atom_beq_true matched
    simp [same, b, a, Term.text, BEq.beq]
  | _ => simp [Term.put, Term.get, b, a, Term.text, BEq.beq]

theorem canonical_put_other {item value : Term} {key : String}
    (canonical : CanonicalQueueItem item) (different : key ≠ "queue_id") :
    CanonicalQueueItem (item.put (b key) value) := by
  obtain ⟨fields, same, binary, positive⟩ := canonical
  subst item
  have updatedBinary : (((b key, value) :: fields.filter (fun pair => !(pair.1 == b key))).all
      (fun pair => pair.1.isBinary)) = true := by
    simp only [List.all_cons, b, Term.text, Term.isBinary, Bool.true_and]
    apply List.all_eq_true.mpr
    intro pair member
    exact List.all_eq_true.mp binary pair (List.mem_filter.mp member).1
  refine ⟨_, rfl, updatedBinary, ?_⟩
  have before := binary_map_atom_nil "queue_id" binary
  have after := binary_map_atom_nil "queue_id" updatedBinary
  change ((Term.map fields).put (b key) value).get (a "queue_id") = nil at after
  simpa only [queueId, get_put_binary_other _ _ different, before, after] using positive

def AllocatedItem (item : Term) (id : Int) (payload : Term) : Prop :=
  (∃ fields, item = .map fields ∧ fields.all (fun pair => pair.1.isBinary) = true) ∧
  item.get (b "queue_id") = i id ∧ item.get (b "payload") = payload

theorem allocated_canonical {item payload : Term} {id : Int}
    (allocated : AllocatedItem item id payload) (positive : 0 < id) : CanonicalQueueItem item := by
  obtain ⟨⟨fields, same, binary⟩, identity, _⟩ := allocated
  refine ⟨fields, same, binary, ?_⟩
  simpa [queueId, identity, Term.default, Term.truthy, i, integerValue] using positive

theorem nonnilPut_allocated {s value payload t : Term} {key : String} {id : Int} {j r : List Term}
    (allocated : AllocatedItem s id payload) (notId : key ≠ "queue_id") (notPayload : key ≠ "payload")
    (h : nonnilPut s (b key) value j = .ok (t, r)) : AllocatedItem t id payload := by
  unfold nonnilPut at h
  split at h
  · have same := put_ok h
    subst t
    obtain ⟨⟨fields, same, binary⟩, identity, content⟩ := allocated
    refine ⟨?_, (get_put_binary_other _ _ notId).trans identity,
      (get_put_binary_other _ _ notPayload).trans content⟩
    subst s
    refine ⟨_, rfl, ?_⟩
    simp only [List.all_cons, b, Term.text, Term.isBinary, Bool.true_and]
    apply List.all_eq_true.mpr
    intro pair member
    exact List.all_eq_true.mp binary pair (List.mem_filter.mp member).1
  · have same := pure_ok h
    subst t
    exact allocated

theorem allocated_base (id : Int) (wake payload : Term) :
    AllocatedItem (.map [(b "queue_id", i id), (b "wake", wake), (b "payload", payload)]) id payload := by
  refine ⟨⟨_, rfl, rfl⟩, ?_, ?_⟩
  all_goals simp +decide [Term.get, BEq.beq, b, Term.text]

/-- A non-duplicate append stores the normalized payload under the allocated queue ID. -/
theorem queueAppend_allocates {s e t : Term} {id : Int} {j r : List Term}
    (nextId : s.get (a "next_queue_id") = i id)
    (h : queueAppend s e j = .ok (t, r)) :
    t = s ∨ ∃ item items payload j₁ j₂ j₃ j₄,
      stringify ((e.get (b "payload")).default empty) j₁ = .ok (payload, j₂) ∧
      normalizeQueue (s.get (a "input_queue")) j₃ = .ok (items, j₄) ∧
      AllocatedItem item id payload ∧ t.get (a "input_queue") = list (items ++ [item]) ∧
      t.get (a "next_queue_id") = i (id + 1) := by
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨rawPayload, _, payloadRead, h⟩ := bind_ok h
    have rawValue := (access_ok payloadRead).1
    subst rawPayload
    obtain ⟨payload, j₂, normalized, h⟩ := bind_ok h
    iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨hit, _, _, h⟩ := bind_ok h
    cases hit with
    | true => exact Or.inl (pure_ok h)
    | false =>
      obtain ⟨allocatedId, _, idRead, h⟩ := bind_ok h
      have idValue : allocatedId = i id := by
        simp only [field, fetch_ok_iff] at idRead
        exact idRead.2.2.1.trans nextId
      subst allocatedId
      have defaultId : (i id).default (i 1) = i id := rfl
      rw [defaultId] at h
      obtain ⟨wake, _, _, h⟩ := bind_ok h
      obtain ⟨item₁, _, first, h⟩ := bind_ok h
      have allocated₁ := nonnilPut_allocated (allocated_base id _ payload) (by decide) (by decide) first
      obtain ⟨item₂, _, second, h⟩ := bind_ok h
      have allocated₂ := nonnilPut_allocated allocated₁ (by decide) (by decide) second
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨item, _, third, h⟩ := bind_ok h
      have allocated := nonnilPut_allocated allocated₂ (by decide) (by decide) third
      obtain ⟨rawQueue, _, queueRead, h⟩ := bind_ok h
      have queueValue : rawQueue = s.get (a "input_queue") := by
        simp only [field, fetch_ok_iff] at queueRead
        exact queueRead.2.2.1
      subst rawQueue
      obtain ⟨items, j₄, queueNormalized, h⟩ := bind_ok h
      obtain ⟨oldId, _, oldRead, h⟩ := bind_ok h
      have oldValue : oldId = i id := by
        simp only [field, fetch_ok_iff] at oldRead
        exact oldRead.2.2.1.trans nextId
      subst oldId
      obtain ⟨increment, _, incrementRead, h⟩ := bind_ok h
      have incrementValue : increment = i (id + 1) := pure_ok incrementRead
      subst increment
      obtain ⟨next, _, nextRead, h⟩ := bind_ok h
      rw [defaultId, maximum_integer] at nextRead
      have nextValue : next = i (id + 1) := by
        have eq := (Prod.mk.inj (Except.ok.inj nextRead)).1.symm
        simpa [Int.max_eq_right (show id ≤ id + 1 by omega)] using eq
      subst next
      iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, h⟩ := write_cons h
      have queueFrame := (write_field_frame (key := "input_queue") h rfl).trans (get_put_same _ _ _)
      obtain ⟨_, h⟩ := write_cons h
      have nextFrame := (write_field_frame (key := "next_queue_id") h rfl).trans (get_put_same _ _ _)
      exact Or.inr ⟨item, items, payload, _, j₂, _, j₄, normalized, queueNormalized,
        allocated, queueFrame, nextFrame⟩

def QueueAllocated (s : Term) : Prop :=
  ∃ items next, s.get (a "input_queue") = list items ∧ s.get (a "next_queue_id") = i next ∧
    0 < next ∧ (∀ item ∈ items, CanonicalQueueItem item) ∧
    (∀ item ∈ items, queueId item < next) ∧ (items.map queueId).Nodup

theorem queue_allocated_empty {s : Term} (queue : s.get (a "input_queue") = list [])
    (next : s.get (a "next_queue_id") = i 1) : QueueAllocated s :=
  ⟨[], 1, queue, next, by decide, by simp, by simp, by simp⟩

/-- Actual allocation keeps canonical items, unique IDs, and a next ID above every queue item. -/
theorem queueAppend_allocated {s e t : Term} {j r : List Term}
    (invariant : QueueAllocated s) (h : queueAppend s e j = .ok (t, r)) : QueueAllocated t := by
  obtain ⟨items, next, read, nextId, positive, canonical, bounded, unique⟩ := invariant
  rcases queueAppend_allocates nextId h with same | allocated
  · subst t
    exact ⟨items, next, read, nextId, positive, canonical, bounded, unique⟩
  · obtain ⟨item, normalized, payload, _, _, _, _, _, normalizedRead, allocated, queue, nextRead⟩ := allocated
    rw [read] at normalizedRead
    have perm := normalizeQueue_permutation canonical normalizedRead
    have identity : queueId item = next := by
      simp [queueId, allocated.2.1, Term.default, Term.truthy, i, integerValue]
    have normalizedUnique : (normalized.map queueId).Nodup := (perm.map queueId).nodup_iff.mpr unique
    refine ⟨normalized ++ [item], next + 1, queue, nextRead, by omega, ?_, ?_, ?_⟩
    · intro current member
      rcases List.mem_append.mp member with old | fresh
      · exact canonical current (perm.mem_iff.mp old)
      · have same : current = item := by simpa using fresh
        subst current
        exact allocated_canonical allocated positive
    · intro current member
      rcases List.mem_append.mp member with old | fresh
      · have bound := bounded current (perm.mem_iff.mp old)
        omega
      · have same : current = item := by simpa using fresh
        subst current
        omega
    · apply List.pairwise_map.mpr
      apply List.pairwise_append.mpr
      refine ⟨List.pairwise_map.mp normalizedUnique, by simp, ?_⟩
      intro current member fresh singleton
      have same : fresh = item := by simpa using singleton
      subst fresh
      have bound := bounded current (perm.mem_iff.mp member)
      omega

theorem pruneResultRefs_next_id {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) :
    t.get (a "next_queue_id") = s.get (a "next_queue_id") := by
  unfold pruneResultRefs at h
  repeat' first
    | exact write_field_frame h rfl
    | (have same := pure_ok h; subst t; rfl)
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem queueConsume_next_id {s e t : Term} {j r : List Term}
    (h : queueConsume s e j = .ok (t, r)) :
    t.get (a "next_queue_id") = s.get (a "next_queue_id") := by
  unfold queueConsume at h
  iterate 4 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_next_id pruned).trans (write_field_frame written rfl)

theorem queueAck_next_id {s e t : Term} {j r : List Term}
    (h : queueAck s e j = .ok (t, r)) :
    t.get (a "next_queue_id") = s.get (a "next_queue_id") := by
  unfold queueAck at h
  iterate 6 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, written, pruned⟩ := bind_ok h
  exact (pruneResultRefs_next_id pruned).trans (write_field_frame written rfl)


theorem filterAuxM_sublist {p : Term → KernelM Bool} {xs acc ys : List Term} {j r : List Term}
    (h : List.filterAuxM p xs acc j = .ok (ys, r)) : ys.reverse.Sublist (acc.reverse ++ xs) := by
  induction xs generalizing acc j with
  | nil => rw [pure_ok h]; simp
  | cons x xs ih =>
    unfold List.filterAuxM at h
    obtain ⟨keep, _, _, h⟩ := bind_ok h
    cases keep with
    | true => simpa [List.reverse_cons, List.append_assoc] using ih h
    | false =>
      exact (ih h).trans ((List.Sublist.cons x (List.Sublist.refl xs)).append_left acc.reverse)

theorem filterM_sublist {p : Term → KernelM Bool} {xs ys : List Term} {j r : List Term}
    (h : xs.filterM p j = .ok (ys, r)) : ys.Sublist xs := by
  unfold List.filterM at h
  obtain ⟨rev, _, filtered, h⟩ := bind_ok h
  rw [pure_ok h]
  simpa using filterAuxM_sublist filtered

theorem queueAllocated_sublist {s t : Term} {items normalized kept : List Term}
    (invariant : QueueAllocated s) (read : s.get (a "input_queue") = list items)
    (nextRead : t.get (a "next_queue_id") = s.get (a "next_queue_id"))
    (queue : t.get (a "input_queue") = list kept)
    (permutation : normalized.Perm items) (subset : kept.Sublist normalized) : QueueAllocated t := by
  obtain ⟨original, next, originalRead, nextId, positive, canonical, bounded, unique⟩ := invariant
  have same : original = items := Term.list.inj (originalRead.symm.trans read)
  subst original
  have member : ∀ item ∈ kept, item ∈ items :=
    fun item present => permutation.mem_iff.mp (subset.subset present)
  exact ⟨kept, next, queue, nextRead.trans nextId, positive,
    fun item present => canonical item (member item present),
    fun item present => bounded item (member item present),
    ((permutation.map queueId).nodup_iff.mpr unique).sublist (subset.map queueId)⟩

/-- Even a non-integer retirement request cannot break queue allocation: filtering creates no IDs. -/
theorem queueConsume_allocation {s e t : Term} {j r : List Term}
    (invariant : QueueAllocated s) (h : queueConsume s e j = .ok (t, r)) : QueueAllocated t := by
  have original := invariant
  obtain ⟨items, _, read, _, _, canonical, _⟩ := original
  have next := queueConsume_next_id h
  unfold queueConsume at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
  have same : raw = list items := by
    simp only [field, fetch_ok_iff] at rawRead
    exact rawRead.2.2.1.trans read
  subst raw
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  obtain ⟨kept, _, filtered, h⟩ := bind_ok h
  obtain ⟨written, _, updated, pruned⟩ := bind_ok h
  obtain ⟨_, updated⟩ := write_cons updated
  have equal := pure_ok updated
  subst written
  have queue := (pruneResultRefs_queue pruned).trans (get_put_same _ _ _)
  exact queueAllocated_sublist invariant read next queue
    (normalizeQueue_permutation canonical normalizedRead) (filterM_sublist filtered)

theorem queueAck_allocation {s e t : Term} {j r : List Term}
    (invariant : QueueAllocated s) (h : queueAck s e j = .ok (t, r)) : QueueAllocated t := by
  have original := invariant
  obtain ⟨items, _, read, _, _, canonical, _⟩ := original
  have next := queueAck_next_id h
  unfold queueAck at h
  iterate 3 obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
  have same : raw = list items := by
    simp only [field, fetch_ok_iff] at rawRead
    exact rawRead.2.2.1.trans read
  subst raw
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  obtain ⟨kept, _, filtered, h⟩ := bind_ok h
  obtain ⟨written, _, updated, pruned⟩ := bind_ok h
  iterate 2 obtain ⟨_, updated⟩ := write_cons updated
  have equal := pure_ok updated
  subst written
  have queue := (pruneResultRefs_queue pruned).trans (get_put_same _ _ _)
  exact queueAllocated_sublist invariant read next queue
    (normalizeQueue_permutation canonical normalizedRead) (filterM_sublist filtered)

end VerifiedKernel.Session.WorkConservation
