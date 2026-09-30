import VerifiedKernelProofs.Session.WorkInputTermLedger

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem queueAppend_fresh_changes {s t event : Term} {j r : List Term}
    (invariant : QueueAllocated s)
    (fresh : ∀ normalized keys before middle after,
      stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle) →
      queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after) →
      ∀ key ∈ keys, IdentityAbsent (s.get (a "input_dedupe")) key)
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
    obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨ledger, _, ledgerRead, h⟩ := bind_ok h
    have ledgerEq := field_value ledgerRead
    subst ledger
    obtain ⟨hit, _, hitRead, h⟩ := bind_ok h
    have noHit := dedupeHit_absent (fresh _ _ _ _ _ normalizedRead keysRead) hitRead
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

theorem nonnull_not_truthy {source : Term} (nonnull : (source == nil) = false)
    (negative : source.truthy = false) : source = a "false" := by
  cases source with
  | atom name =>
    by_cases isNil : name = "nil"
    · subst name; contradiction
    by_cases isFalse : name = "false"
    · subst name; rfl
    simp [Term.truthy, isNil, isFalse] at negative
  | _ => contradiction

theorem inputEvent_selected_key {session payload now event normalized source : Term}
    {keys j r before middle after : List Term}
    (nonnull : (source == nil) = false)
    (generated : Command.inputEvent session source payload now j = .ok (event, r))
    (normalizedRead : stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle))
    (keysRead : queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after)) :
    (event.get (b "dedupe_key")).default (keys.head?.getD nil) = source := by
  have present : (source != nil) = true := by simp only [bne, nonnull, Bool.not_false]
  obtain ⟨_, kind, dedupe, outerSource, fields, body, different⟩ :=
    inputEvent_source_term_fields present generated
  rw [dedupe]
  cases positive : source.truthy with
  | true => simp only [Term.default, positive, ↓reduceIte]
  | false =>
    have same := nonnull_not_truthy nonnull positive
    rw [same] at dedupe body ⊢
    rw [body] at normalizedRead
    change stringify (Command.compact (("source_message_id", a "false") :: fields)) before =
      .ok (normalized, middle) at normalizedRead
    obtain ⟨converted, fuel, first, last, convertedRead, innerSource⟩ :=
      stringify_compact_head_value (by rfl) different normalizedRead
    have convertedEq := stringifyFuel_unchanged (by rfl) convertedRead
    rw [convertedEq] at innerSource
    unfold queueKeys at keysRead
    obtain ⟨firstKey, _, firstRead, keysRead⟩ := bind_ok keysRead
    have firstEq := (access_ok firstRead).1.trans dedupe
    subst firstKey
    obtain ⟨secondKey, _, secondRead, keysRead⟩ := bind_ok keysRead
    have secondEq := (access_ok secondRead).1.trans outerSource
    subst secondKey
    obtain ⟨thirdKey, _, thirdRead, keysRead⟩ := bind_ok keysRead
    have thirdEq := (access_ok thirdRead).1.trans innerSource
    subst thirdKey
    rw [kind] at keysRead
    have keysEq : keys = [a "false"] := pure_ok keysRead
    rw [keysEq]
    rfl

theorem inputEvent_append_term_fields {s t session payload now event source : Term}
    {j r before after : List Term}
    (nonnull : (source == nil) = false)
    (generated : Command.inputEvent session source payload now before = .ok (event, after))
    (changed : t ≠ s) (h : queueAppend s event j = .ok (t, r)) :
    ∃ item items normalized j₁ j₂ j₃ j₄,
      stringify ((event.get (b "payload")).default empty) j₁ = .ok (normalized, j₂) ∧
      normalizeQueue (s.get (a "input_queue")) j₃ = .ok (items, j₄) ∧
      t.get (a "input_queue") = list (items ++ [item]) ∧
      item.get (b "kind") = b "user_message" ∧ item.get (b "dedupe_key") = source ∧
      item.get (b "payload") = normalized := by
  have present : (source != nil) = true := by simp only [bne, nonnull, Bool.not_false]
  have fields := inputEvent_source_term_fields present generated
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
    obtain ⟨keys, _, keysRead, h⟩ := bind_ok h
    have selectedKey := inputEvent_selected_key nonnull generated normalizedRead keysRead
    obtain ⟨key, _, keyRead, h⟩ := bind_ok h
    have keyEq := (access_ok keyRead).1
    subst key
    rw [selectedKey] at h
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
      change nonnilPut _ _ source _ = _ at second
      simp only [nonnilPut, present, ↓reduceIte] at second
      have secondEq := put_ok second
      subst item₂
      obtain ⟨created, _, _, h⟩ := bind_ok h
      obtain ⟨item, _, third, h⟩ := bind_ok h
      have kindField := nonnilPut_binary_frame (key := "kind") (by decide) third
      have keyField := nonnilPut_binary_frame (key := "dedupe_key") (by decide) third
      have payloadField := nonnilPut_binary_frame (key := "payload") (by decide) third
      have kindValue : item.get (b "kind") = b "user_message" := by
        rw [kindField, get_put_binary_other _ _ (by decide), get_put_binary_same]
      have keyValue : item.get (b "dedupe_key") = source := by
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

def MainTermInputFact (event source item : Term) : Prop :=
  item.get (b "kind") = b "user_message" ∧ item.get (b "dedupe_key") = source ∧
  ∃ normalized j r, stringify ((event.get (b "payload")).default empty) j = .ok (normalized, r) ∧
    item.get (b "payload") = normalized

theorem inputEvent_append_term_creates {s t session payload now event source : Term}
    {j r before after : List Term}
    (nonnull : (source == nil) = false)
    (generated : Command.inputEvent session source payload now before = .ok (event, after))
    (invariant : QueueAllocated s)
    (fresh : ∀ normalized keys first middle last,
      stringify ((event.get (b "payload")).default empty) first = .ok (normalized, middle) →
      queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, last) →
      ∀ key ∈ keys, IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : queueAppend s event j = .ok (t, r)) :
    ∃ item, MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
      ∀ sealed, ConcreteRepresented t sealed item := by
  have changed := queueAppend_fresh_changes invariant fresh h
  obtain ⟨item, items, normalized, j₁, j₂, j₃, j₄, normalizedRead, _, queueValue, kind, key, payloadValue⟩ :=
    inputEvent_append_term_fields nonnull generated changed h
  obtain ⟨queue, _, read, _, _, canonical, _⟩ := queueAppend_allocated invariant h
  have same := Term.list.inj (read.symm.trans queueValue)
  subst queue
  have member : item ∈ items ++ [item] := List.mem_append_right _ (by simp)
  exact ⟨item, ⟨kind, key, normalized, j₁, j₂, normalizedRead, payloadValue⟩,
    canonical _ member, fun _ => Or.inl ⟨items ++ [item], item, queueValue, member,
      rfl, rfl, rfl, rfl⟩⟩

end VerifiedKernel.Session.WorkConservation
