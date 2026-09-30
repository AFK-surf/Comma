import VerifiedKernelProofs.Session.WorkInputIdentity
import VerifiedKernelProofs.Session.WorkResidentSafety

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem inputEvent_append_changes {s t session payload now event : Term} {source : ByteArray}
    {j r before after : List Term}
    (generated : Command.inputEvent session (.binary source) payload now before = .ok (event, after))
    (invariant : QueueAllocated s)
    (fresh : IdentityAbsent (s.get (a "input_dedupe")) (.binary source))
    (h : queueAppend s event j = .ok (t, r)) : t ≠ s := by
  intro same
  subst t
  obtain ⟨queue, next, queueRead, _, _, canonical, _, _⟩ := invariant
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
    have rawEq := (access_ok rawRead).1
    subst raw
    obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
    obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
    have sameKeys := inputEvent_queueKeys_source generated normalizedRead keysRead
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
    have ledgerEq := field_value ledgerRead
    subst ledger
    obtain ⟨hit, _, hitRead, h⟩ := bind_ok h
    have noHit := dedupeHit_absent (fun key member => by rw [sameKeys key member]; exact fresh) hitRead
    subst hit
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    repeat
      fail_if_success (bind_field_is h "input_queue"; change (field s "input_queue" >>= _) _ = _ at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨rawQueue, _, rawQueueRead, h⟩ := bind_ok h
    have rawQueueEq := (field_value rawQueueRead).trans queueRead
    subst rawQueue
    obtain ⟨items, _, itemsRead, h⟩ := bind_ok h
    have permutation := normalizeQueue_permutation canonical itemsRead
    repeat
      fail_if_success (head_is h [write]; change write _ _ _ = _ at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, written⟩ := write_cons h
    have result := (write_field_frame (key := "input_queue") written rfl).trans (get_put_same _ _ _)
    have equal := congrArg List.length (Term.list.inj (queueRead.symm.trans result))
    simp only [List.length_append, List.length_singleton] at equal
    have sameLength := permutation.length_eq
    omega

theorem nonnilPut_binary_frame {s t value : Term} {key name : String} {j r : List Term}
    (different : name ≠ key) (h : nonnilPut s (b name) value j = .ok (t, r)) :
    t.get (b key) = s.get (b key) := by
  unfold nonnilPut at h
  split at h
  · rw [put_ok h]; exact get_put_binary_other _ _ different
  · rw [pure_ok h]

theorem inputEvent_append_fields {s t session payload now event : Term} {source : ByteArray}
    {j r before after : List Term}
    (generated : Command.inputEvent session (.binary source) payload now before = .ok (event, after))
    (changed : t ≠ s) (h : queueAppend s event j = .ok (t, r)) :
    ∃ item items normalized j₁ j₂ j₃ j₄,
      stringify ((event.get (b "payload")).default empty) j₁ = .ok (normalized, j₂) ∧
      normalizeQueue (s.get (a "input_queue")) j₃ = .ok (items, j₄) ∧
      t.get (a "input_queue") = list (items ++ [item]) ∧
      item.get (b "kind") = b "user_message" ∧ item.get (b "dedupe_key") = .binary source ∧
      item.get (b "payload") = normalized := by
  have fields := inputEvent_source_fields generated
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨kind, _, kindRead, h⟩ := bind_ok h
    have kindEq := (access_ok kindRead).1.trans fields.2.1
    subst kind
    obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
    have rawEq := (access_ok rawRead).1
    subst raw
    obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
    obtain ⟨keys, _, _, h⟩ := bind_ok h
    obtain ⟨key, _, keyRead, h⟩ := bind_ok h
    have keyEq := (access_ok keyRead).1.trans fields.2.2.1
    subst key
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨hit, _, _, h⟩ := bind_ok h
    split at h
    · exact (changed (pure_ok h)).elim
    · obtain ⟨id, _, _, h⟩ := bind_ok h
      obtain ⟨wake, _, _, h⟩ := bind_ok h
      obtain ⟨item₁, _, first, h⟩ := bind_ok h
      simp only [nonnilPut, show (b "user_message" != nil) = true from rfl, ↓reduceIte] at first
      have firstEq := put_ok first
      subst item₁
      obtain ⟨item₂, _, second, h⟩ := bind_ok h
      change nonnilPut _ _ (.binary source) _ = _ at second
      simp only [nonnilPut, show (Term.binary source != nil) = true from rfl, ↓reduceIte] at second
      have secondEq := put_ok second
      subst item₂
      obtain ⟨created, _, _, h⟩ := bind_ok h
      obtain ⟨item, _, third, h⟩ := bind_ok h
      have kindField := nonnilPut_binary_frame (key := "kind") (by decide) third
      have keyField := nonnilPut_binary_frame (key := "dedupe_key") (by decide) third
      have payloadField := nonnilPut_binary_frame (key := "payload") (by decide) third
      have kindValue : item.get (b "kind") = b "user_message" := by
        rw [kindField, get_put_binary_other _ _ (by decide), get_put_binary_same]
      have keyValue : item.get (b "dedupe_key") = .binary source := by
        rw [keyField, get_put_binary_same]
      have payloadValue : item.get (b "payload") = normalized := by
        rw [payloadField, get_put_binary_other _ _ (by decide), get_put_binary_other _ _ (by decide)]
        simp +decide [Term.get, binary_key_beq]
      obtain ⟨rawQueue, _, rawQueueRead, h⟩ := bind_ok h
      have rawQueueEq := field_value rawQueueRead
      subst rawQueue
      obtain ⟨items, _, normalizedQueue, h⟩ := bind_ok h
      repeat
        fail_if_success (head_is h [write]; change write _ _ _ = _ at h)
        obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, written⟩ := write_cons h
      have queueValue := (write_field_frame (key := "input_queue") written rfl).trans (get_put_same _ _ _)
      exact ⟨item, items, normalized, _, _, _, _, normalizedRead, normalizedQueue, queueValue,
        kindValue, keyValue, payloadValue⟩

/-- A proof-only relation between the requested input and its concrete queue item. -/
def MainInputFact (event : Term) (source : ByteArray) (item : Term) : Prop :=
  item.get (b "kind") = b "user_message" ∧ item.get (b "dedupe_key") = .binary source ∧
  ∃ normalized j r, stringify ((event.get (b "payload")).default empty) j = .ok (normalized, r) ∧
    item.get (b "payload") = normalized

theorem inputEvent_append_creates {s t session payload now event : Term} {source : ByteArray}
    {j r before after : List Term}
    (generated : Command.inputEvent session (.binary source) payload now before = .ok (event, after))
    (invariant : QueueAllocated s)
    (fresh : IdentityAbsent (s.get (a "input_dedupe")) (.binary source))
    (h : queueAppend s event j = .ok (t, r)) :
    ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
      ∀ sealed, ConcreteRepresented t sealed item := by
  have changed := inputEvent_append_changes generated invariant fresh h
  obtain ⟨item, items, normalized, j₁, j₂, j₃, j₄, normalizedRead, _, queueValue, kind, key, payloadValue⟩ :=
    inputEvent_append_fields generated changed h
  obtain ⟨queue, _, read, _, _, canonical, _⟩ := queueAppend_allocated invariant h
  have same : queue = items ++ [item] := Term.list.inj (read.symm.trans queueValue)
  subst queue
  have member : item ∈ items ++ [item] := List.mem_append_right _ List.mem_cons_self
  exact ⟨item, ⟨kind, key, normalized, j₁, j₂, normalizedRead, payloadValue⟩, canonical item member,
    fun _ => Or.inl ⟨items ++ [item], item, queueValue, member, rfl, rfl, rfl, rfl⟩⟩

theorem resident_main_input_creates {s t payload now event : Term} {source : ByteArray}
    {j r observations : List Term}
    (generated : Command.inputEvent (s.get (a "session_id")) (.binary source) payload now j = .ok (event, r))
    (invariant : QueueAllocated s)
    (fresh : IdentityAbsent (s.get (a "input_dedupe")) (.binary source))
    (execution : ResidentTrace (runTrusted s event observations) (.tuple [a "done", t])) :
    ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
      ∀ sealed, ConcreteRepresented t sealed item := by
  obtain ⟨reduced, normalized, before, after, prepared, activity⟩ := resident_execution_step execution
  cases normalized with
  | none => exact (prepareTrusted_canonical_not_skipped (inputEvent_binary_keys generated)
      (inputEvent_session generated) prepared).elim
  | some normalized =>
    obtain ⟨innerBefore, read, innerAfter, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys (inputEvent_binary_keys generated) read
    subst normalized
    have kind := (inputEvent_source_fields generated).1
    have append : queueAppend s event innerBefore = .ok (reduced, innerAfter) := by
      simpa +decide [inner, kind] using call
    obtain ⟨item, fact, canonical, represented⟩ := inputEvent_append_creates generated invariant fresh append
    exact ⟨item, fact, canonical, fun sealed =>
      (concrete_representation_frame (activity_frame_work activity)).mp (represented sealed)⟩

theorem validateQueue_identity_read {kind event : Term} {j r : List Term}
    (h : validateQueue kind event j = .ok ((), r)) :
    ∃ normalized keys before middle after,
      stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle) ∧
      queueKeys event normalized kind middle = .ok (keys, after) ∧ keys ≠ [] := by
  unfold validateQueue at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨raw, _, rawRead, h⟩ := bind_ok h
    have rawEq := (access_ok rawRead).1
    subst raw
    obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
    obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
    refine ⟨normalized, keys, _, _, _, normalizedRead, keysRead, ?_⟩
    intro emptyKeys
    subst keys
    simp only [List.isEmpty_nil, ↓reduceIte] at h
    obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim

theorem inputEvent_append_identity {s t session payload now event : Term} {source : ByteArray}
    {j r before after : List Term}
    (generated : Command.inputEvent session (.binary source) payload now before = .ok (event, after))
    (h : queueAppend s event j = .ok (t, r)) :
    ∃ groups first last, Command.inputIdentityGroups event first = .ok (groups, last) ∧
      Term.binary source ∈ groups.flatten := by
  unfold queueAppend at h
  split at h
  · obtain ⟨_, _, failed, _⟩ := bind_ok h
    exact (fail_ok failed).elim
  · obtain ⟨unit, _, validated, _⟩ := bind_ok h
    cases unit
    obtain ⟨normalized, keys, first, middle, last, normalizedRead, keysRead, nonempty⟩ :=
      validateQueue_identity_read validated
    have onlySource := inputEvent_queueKeys_source generated normalizedRead keysRead
    have sourceMember : Term.binary source ∈ keys := by
      cases keys with
      | nil => exact (nonempty rfl).elim
      | cons key keys =>
        have same := onlySource key List.mem_cons_self
        rw [← same]
        exact List.mem_cons_self
    have kind := (inputEvent_source_fields generated).1
    refine ⟨[keys], first, last, ?_, by simpa using sourceMember⟩
    simp +decide only [Command.inputIdentityGroups, kind]
    simp only [↓reduceIte, Bind.bind, StateT.bind, Except.bind, normalizedRead, keysRead,
      Pure.pure, StateT.pure, Except.pure]

end VerifiedKernel.Session.WorkConservation
