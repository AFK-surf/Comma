import VerifiedKernelProofs.Session.WorkLedgerInput

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

def stringifyFieldStep (fuel : Nat) (acc pair : Term) : KernelM Term := do
  let .tuple [key, item] := pair | fail "function_clause"
  let key ← stringChars key
  put acc key (← stringifyFuel fuel item)

theorem enumFold_named_map {α : Type} {fields : List (String × Term)} {initial final : α}
    {step : α → Term → KernelM α} {j r : List Term}
    (h : enumFold (.map (fields.map (fun pair => (b pair.1, pair.2)))) initial step j = .ok (final, r)) :
    (fields.map (fun pair => Term.tuple [b pair.1, pair.2])).foldlM step initial j = .ok (final, r) := by
  have plain : (Term.map (fields.map (fun pair => (b pair.1, pair.2)))).has (a "__struct__") = false := by
    simp [Term.has, List.any_map, b, a, Term.text, BEq.beq]
  have same : enumFold (.map (fields.map (fun pair => (b pair.1, pair.2)))) initial step j =
      enumFold (.list (fields.map (fun pair => Term.tuple [b pair.1, pair.2]))) initial step j := by
    simp only [enumFold, enumUntil, plain, Bool.not_false, ↓reduceIte, List.map_map, Function.comp_def]
  rw [same] at h
  obtain ⟨items, folded, enumerated⟩ := enumFold_ok h
  rw [enumerated _ rfl] at folded
  exact folded

theorem get_put_binary_same (state value : Term) (key : String) :
    (state.put (b key) value).get (b key) = value := by
  cases state <;> simp [Term.put, Term.get, binary_key_beq]

theorem stringifyFuel_binary_value {fuel : Nat} {raw : ByteArray} {value : Term} {j r : List Term}
    (h : stringifyFuel fuel (.binary raw) j = .ok (value, r)) : value = .binary raw := by
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel => exact pure_ok h

theorem stringify_named_fold_frame {fields : List (String × Term)} {key : String} {s t : Term}
    {fuel : Nat} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : (fields.map (fun pair => Term.tuple [b pair.1, pair.2])).foldlM
      (stringifyFieldStep fuel) s j = .ok (t, r)) : t.get (b key) = s.get (b key) := by
  induction fields generalizing s j with
  | nil => rw [pure_ok h]
  | cons pair fields ih =>
    simp only [List.map_cons, List.foldlM_cons] at h
    obtain ⟨next, _, head, tail⟩ := bind_ok h
    unfold stringifyFieldStep at head
    obtain ⟨name, _, nameRead, head⟩ := bind_ok head
    have nameEq := pure_ok nameRead
    subst name
    obtain ⟨value, _, _, head⟩ := bind_ok head
    have nextEq := put_ok head
    subst next
    rw [ih (fun field member => different field (List.mem_cons_of_mem _ member)) tail]
    exact get_put_binary_other _ _ (different pair List.mem_cons_self)

theorem stringifyFuel_named_head {fields : List (String × Term)} {key : String} {raw : ByteArray}
    {value : Term} {fuel : Nat} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringifyFuel fuel (.map (((key, .binary raw) :: fields).map (fun pair => (b pair.1, pair.2)))) j =
      .ok (value, r)) : value.get (b key) = .binary raw := by
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel =>
    unfold stringifyFuel at h
    change enumFold _ empty (stringifyFieldStep fuel) j = .ok (value, r) at h
    have folded := enumFold_named_map h
    simp only [List.map_cons, List.foldlM_cons] at folded
    obtain ⟨next, _, head, tail⟩ := bind_ok folded
    unfold stringifyFieldStep at head
    obtain ⟨name, _, nameRead, head⟩ := bind_ok head
    have nameEq := pure_ok nameRead
    subst name
    obtain ⟨converted, _, convertedRead, head⟩ := bind_ok head
    have convertedEq := stringifyFuel_binary_value convertedRead
    subst converted
    have nextEq := put_ok head
    subst next
    rw [stringify_named_fold_frame different tail, get_put_binary_same]

theorem stringify_named_head {fields : List (String × Term)} {key : String} {raw : ByteArray}
    {value : Term} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringify (.map (((key, .binary raw) :: fields).map (fun pair => (b pair.1, pair.2)))) j =
      .ok (value, r)) : value.get (b key) = .binary raw := by
  unfold stringify at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact stringifyFuel_named_head different h

theorem stringify_compact_head {fields : List (String × Term)} {key : String} {raw : ByteArray}
    {value : Term} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringify (Command.compact ((key, .binary raw) :: fields)) j = .ok (value, r)) :
    value.get (b key) = .binary raw := by
  unfold Command.compact at h
  simp only [List.filter_cons, show (Term.binary raw != nil) = true from rfl, ↓reduceIte] at h
  exact stringify_named_head (fun pair member => different pair (List.mem_filter.mp member).1) h

theorem compact_lookup (pairs : List (String × Term)) (key : String) :
    (Command.compact pairs).get (b key) =
      ((pairs.find? (fun pair => pair.2 != nil && pair.1 == key)).map Prod.snd).getD nil := by
  have names (left right : String) : (left == right) = decide (left = right) := by
    by_cases same : left = right <;> simp [same]
  simp [Command.compact, Term.get, List.find?_map, List.find?_filter, binary_key_beq,
    Function.comp_def, nil, a, names]

theorem compact_not_nil (pairs : List (String × Term)) : (Command.compact pairs != nil) = true := rfl

theorem inputEvent_source_fields {session payload now event : Term} {source : ByteArray} {j r : List Term}
    (h : Command.inputEvent session (.binary source) payload now j = .ok (event, r)) :
    event.get (b "type") = b "queue_append" ∧ event.get (b "kind") = b "user_message" ∧
    event.get (b "dedupe_key") = .binary source ∧ event.get (b "source_message_id") = nil ∧
    ∃ fields : List (String × Term),
      event.get (b "payload") = Command.compact (("source_message_id", .binary source) :: fields) ∧
      ∀ pair ∈ fields, pair.1 ≠ "source_message_id" := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  have eventEq := pure_ok h
  subst event
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  all_goals simp +decide [compact_lookup, compact_not_nil, List.find?_cons]
  all_goals try rfl
  refine ⟨_, rfl, ?_⟩
  intro name value member
  simp only [List.mem_cons, List.mem_singleton, Prod.mk.injEq] at member
  rcases member with ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ |
    ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ <;> simp_all

theorem uniq_binary_subset {items : List Term} (binary : items.all Term.isBinary = true) :
    (uniq items).Sublist items := by
  rw [uniq_binary_fold items binary]
  simpa only [List.reverse_nil, List.nil_append] using binaryIdentityFold_sublist items (∅, [])

theorem inputEvent_queueKeys_source {session payload now event normalized : Term} {source : ByteArray}
    {keys j r before middle after : List Term}
    (generated : Command.inputEvent session (.binary source) payload now j = .ok (event, r))
    (normalizedRead : stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle))
    (keysRead : queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after)) :
    ∀ key ∈ keys, key = .binary source := by
  obtain ⟨_, kind, dedupe, outerSource, fields, body, different⟩ := inputEvent_source_fields generated
  rw [body] at normalizedRead
  change stringify (Command.compact (("source_message_id", .binary source) :: fields)) before =
    .ok (normalized, middle) at normalizedRead
  have innerSource := stringify_compact_head different normalizedRead
  unfold queueKeys at keysRead
  obtain ⟨first, _, firstRead, keysRead⟩ := bind_ok keysRead
  have firstEq := (access_ok firstRead).1.trans dedupe
  subst first
  obtain ⟨second, _, secondRead, keysRead⟩ := bind_ok keysRead
  have secondEq := (access_ok secondRead).1.trans outerSource
  subst second
  obtain ⟨third, _, thirdRead, keysRead⟩ := bind_ok keysRead
  have thirdEq := (access_ok thirdRead).1.trans innerSource
  subst third
  rw [kind] at keysRead
  have result : keys = uniq ([Term.binary source, nil, Term.binary source].filter (!missing ·)) := pure_ok keysRead
  rw [result]
  cases absent : missing (Term.binary source)
  · have filtered : ([Term.binary source, nil, Term.binary source].filter (!missing ·)) =
        [Term.binary source, Term.binary source] := by
      simp only [List.filter_cons, absent, show missing nil = true from rfl,
        Bool.not_false, Bool.not_true, Bool.false_eq_true, ↓reduceIte, List.filter_nil]
    rw [filtered]
    intro key member
    have original := (uniq_binary_subset (items := [Term.binary source, Term.binary source]) rfl).subset member
    simpa using original
  · have filtered : ([Term.binary source, nil, Term.binary source].filter (!missing ·)) = [] := by
      simp only [List.filter_cons, absent, show missing nil = true from rfl,
        Bool.not_true, Bool.false_eq_true, ↓reduceIte, List.filter_nil]
    rw [filtered]
    change ∀ key ∈ ([] : List Term), key = .binary source
    simp

theorem inputEvent_session {session payload now event : Term} {source : ByteArray} {j r : List Term}
    (h : Command.inputEvent session (.binary source) payload now j = .ok (event, r)) :
    event.get (b "session_id") = session := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  have eventEq := pure_ok h
  subst event
  cases present : session == nil
  · simp +decide [compact_lookup, List.find?_cons, bne, present]
  · have same := atom_beq_true present
    subst session
    simp +decide [compact_lookup, List.find?_cons, nil]

end VerifiedKernel.Session.WorkConservation
