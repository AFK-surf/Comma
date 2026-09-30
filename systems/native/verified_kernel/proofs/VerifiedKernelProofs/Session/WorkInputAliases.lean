import VerifiedKernelProofs.Session.WorkInputAdmissionActual
import VerifiedKernelProofs.Session.WorkReceiptRecords
import VerifiedKernelProofs.Session.WorkDeterminism
import VerifiedKernelProofs.Proof.TermComparison

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem duplicateDelivery_absent {state source value : Term} {journal rest : List Term}
    (nonnull : (source == nil) = false)
    (call : RoundQuery.duplicateDelivery state source journal = .ok (value, rest))
    (negative : value.truthy = false) :
    IdentityAbsent (state.get (a "input_dedupe")) source := by
  unfold RoundQuery.duplicateDelivery at call
  simp only [nonnull, Bool.false_eq_true, ↓reduceIte] at call
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨present, _, presentRead, call⟩ := bind_ok call
  rw [pure_ok call] at negative
  cases present with
  | false => exact (setMember_value presentRead).symm
  | true => contradiction

theorem deliveryAdmission_accept_source_fresh {state source payload limit : Term}
    {journal rest : List Term}
    (nonnull : (source == nil) = false)
    (call : RoundQuery.deliveryAdmission state (.tuple [source, payload, limit]) journal =
      .ok (a "accept", rest)) :
    IdentityAbsent (state.get (a "input_dedupe")) source := by
  unfold RoundQuery.deliveryAdmission at call
  obtain ⟨duplicate, _, read, call⟩ := bind_ok call
  cases positive : duplicate.truthy with
  | false => exact duplicateDelivery_absent nonnull read positive
  | true =>
    simp only [positive, ↓reduceIte] at call
    have impossible := pure_ok call
    simp [a] at impossible

theorem stringifyFuel_unchanged {fuel : Nat} {source converted : Term} {journal rest : List Term}
    (simple : (source.isMap || source.isList) = false)
    (call : stringifyFuel fuel source journal = .ok (converted, rest)) : converted = source := by
  cases fuel with
  | zero => exact (fail_ok call).elim
  | succ fuel =>
    cases source <;> simp only [Term.isMap, Term.isList, Bool.or_true, Bool.true_or,
      Bool.true_eq_false] at simple
    all_goals first
      | exact pure_ok call
      | (unfold stringifyFuel at call
         obtain ⟨_, _, _, call⟩ := bind_ok call
         exact (fail_ok call).elim)

theorem deliveryAdmission_accept_normalized_fresh {state source payload limit converted : Term}
    {fuel : Nat} {journal rest first last : List Term}
    (nonnull : (source == nil) = false)
    (convertedNonnull : (converted == nil) = false)
    (normalizedRead : stringifyFuel fuel source first = .ok (converted, last))
    (call : RoundQuery.deliveryAdmission state (.tuple [source, payload, limit]) journal =
      .ok (a "accept", rest)) :
    IdentityAbsent (state.get (a "input_dedupe")) converted := by
  have rawAbsent := deliveryAdmission_accept_source_fresh nonnull call
  cases composite : source.isMap || source.isList with
  | false => rwa [stringifyFuel_unchanged composite normalizedRead]
  | true =>
    unfold RoundQuery.deliveryAdmission at call
    obtain ⟨duplicate, _, read, call⟩ := bind_ok call
    cases positive : duplicate.truthy with
    | true =>
      simp only [positive, ↓reduceIte] at call
      have impossible := pure_ok call
      simp [a] at impossible
    | false =>
      simp only [positive, composite, Bool.false_eq_true, ↓reduceIte] at call
      obtain ⟨normalized, _, normalization, call⟩ := bind_ok call
      unfold stringify at normalization
      obtain ⟨_, _, _, normalization⟩ := bind_ok normalization
      have same := stringifyFuel_same_results normalization normalizedRead
      subst normalized
      obtain ⟨hit, _, hitRead, call⟩ := bind_ok call
      cases equal : converted == source with
      | true =>
        unfold IdentityAbsent at rawAbsent ⊢
        cases present : ((state.get (a "input_dedupe")).get (a "map")).has converted with
        | false => rfl
        | true =>
          have impossible := Term.has_of_beq equal present
          rw [rawAbsent] at impossible
          contradiction
      | false =>
        cases hitPositive : hit.truthy with
        | false => exact duplicateDelivery_absent convertedNonnull hitRead hitPositive
        | true =>
          simp only [bne, equal, Bool.not_false, hitPositive, Bool.and_true, ↓reduceIte] at call
          have impossible := pure_ok call
          simp [a] at impossible

theorem stringifyFuel_named_head_value {fields : List (String × Term)} {key : String}
    {raw value : Term} {fuel : Nat} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringifyFuel fuel (.map (((key, raw) :: fields).map (fun pair => (b pair.1, pair.2)))) j =
      .ok (value, r)) :
    ∃ converted fuel first last, stringifyFuel fuel raw first = .ok (converted, last) ∧
      value.get (b key) = converted := by
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
    have nextEq := put_ok head
    subst next
    exact ⟨converted, fuel, _, _, convertedRead,
      (stringify_named_fold_frame different tail).trans (get_put_binary_same _ _ _)⟩

theorem stringify_compact_head_value {fields : List (String × Term)} {key : String}
    {raw value : Term} {j r : List Term}
    (present : (raw != nil) = true)
    (different : ∀ pair ∈ fields, pair.1 ≠ key)
    (h : stringify (Command.compact ((key, raw) :: fields)) j = .ok (value, r)) :
    ∃ converted fuel first last, stringifyFuel fuel raw first = .ok (converted, last) ∧
      value.get (b key) = converted := by
  unfold Command.compact at h
  simp only [List.filter_cons, present, ↓reduceIte] at h
  unfold stringify at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact stringifyFuel_named_head_value
    (fun pair member => different pair (List.mem_filter.mp member).1) h

theorem inputEvent_source_term_fields {session payload now event source : Term} {j r : List Term}
    (present : (source != nil) = true)
    (h : Command.inputEvent session source payload now j = .ok (event, r)) :
    event.get (b "type") = b "queue_append" ∧ event.get (b "kind") = b "user_message" ∧
    event.get (b "dedupe_key") = source ∧ event.get (b "source_message_id") = nil ∧
    ∃ fields : List (String × Term),
      event.get (b "payload") = Command.compact (("source_message_id", source) :: fields) ∧
      ∀ pair ∈ fields, pair.1 ≠ "source_message_id" := by
  unfold Command.inputEvent at h
  repeat obtain ⟨_, _, _, h⟩ := bind_ok h
  have eventEq := pure_ok h
  subst event
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  all_goals simp +decide [compact_lookup, compact_not_nil, present]
  all_goals try rfl
  refine ⟨_, rfl, ?_⟩
  intro name value member
  simp only [List.mem_cons, List.mem_singleton, Prod.mk.injEq] at member
  rcases member with ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ |
    ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ | ⟨rfl, _⟩ <;> simp_all

theorem inputEvent_queueKeys_aliases {session payload now event normalized source : Term}
    {keys j r before middle after : List Term}
    (present : (source != nil) = true)
    (generated : Command.inputEvent session source payload now j = .ok (event, r))
    (normalizedRead : stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle))
    (keysRead : queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after)) :
    ∃ converted fuel first last,
      stringifyFuel fuel source first = .ok (converted, last) ∧
      ∀ key ∈ keys, key = source ∨ key = converted := by
  obtain ⟨_, kind, dedupe, outerSource, fields, body, different⟩ :=
    inputEvent_source_term_fields present generated
  rw [body] at normalizedRead
  change stringify (Command.compact (("source_message_id", source) :: fields)) before =
    .ok (normalized, middle) at normalizedRead
  obtain ⟨converted, fuel, first, last, convertedRead, innerSource⟩ :=
    stringify_compact_head_value present different normalizedRead
  refine ⟨converted, fuel, first, last, convertedRead, ?_⟩
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
  have result : keys = uniq ([source, nil, converted].filter (!missing ·)) := pure_ok keysRead
  rw [result]
  intro key member
  have original := List.mem_filter.mp (uniq_receipt_subset _ key member)
  rcases List.mem_cons.mp original.1 with same | rest
  · exact Or.inl same
  · rcases List.mem_cons.mp rest with same | rest
    · subst key
      have impossible := original.2
      change false = true at impossible
      contradiction
    · exact Or.inr (List.mem_singleton.mp rest)

theorem queueKeys_nonmissing {event payload kind : Term} {keys journal rest : List Term}
    (call : queueKeys event payload kind journal = .ok (keys, rest)) :
    ∀ key ∈ keys, missing key = false := by
  unfold queueKeys at call
  repeat' first
    | (have same := pure_ok call
       rw [same]
       intro key member
       have kept := (List.mem_filter.mp (uniq_receipt_subset _ key member)).2
       cases absent : missing key <;> simp_all)
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem nonmissing_nonnull {key : Term} (present : missing key = false) : (key == nil) = false := by
  cases isNil : key == nil with
  | false => rfl
  | true =>
    have same := atom_beq_true isNil
    subst key
    contradiction

theorem admitted_input_queueKeys_fresh {state entryPayload limit session payload now event normalized source : Term}
    {keys journal rest j r before middle after : List Term}
    (nonnull : (source == nil) = false)
    (admitted : RoundQuery.deliveryAdmission state (.tuple [source, entryPayload, limit]) journal =
      .ok (a "accept", rest))
    (generated : Command.inputEvent session source payload now j = .ok (event, r))
    (normalizedRead : stringify ((event.get (b "payload")).default empty) before = .ok (normalized, middle))
    (keysRead : queueKeys event normalized (event.get (b "kind")) middle = .ok (keys, after)) :
    ∀ key ∈ keys, IdentityAbsent (state.get (a "input_dedupe")) key := by
  have present : (source != nil) = true := by simp only [bne, nonnull, Bool.not_false]
  obtain ⟨converted, fuel, first, last, convertedRead, aliases⟩ :=
    inputEvent_queueKeys_aliases present generated normalizedRead keysRead
  intro key member
  rcases aliases key member with rfl | rfl
  · exact deliveryAdmission_accept_source_fresh nonnull admitted
  · exact deliveryAdmission_accept_normalized_fresh nonnull
      (nonmissing_nonnull (queueKeys_nonmissing keysRead _ member)) convertedRead admitted

end VerifiedKernel.Session.WorkConservation
