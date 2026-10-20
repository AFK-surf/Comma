import VerifiedKernelProofs.Provider.CallKey
import VerifiedKernelProofs.Provider.AnsweredCore

/-!
Lookups after `putField`, the rewrite with which `uniqueChatCallIds` sets wire ids.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- Two lists of the same length that a relation links elementwise. Core Lean has no
`List.Forall₂`, so this namespace provides one. -/
inductive List.Forall₂ {α β : Type} (R : α → β → Prop) : List α → List β → Prop
  | nil : List.Forall₂ R [] []
  | cons {a : α} {b : β} {l₁ : List α} {l₂ : List β} :
      R a b → List.Forall₂ R l₁ l₂ → List.Forall₂ R (a :: l₁) (b :: l₂)

/-! ### Fields under `putField` -/

theorem atom_ne_binary_key {t : Term} {k l : String} (h : (t == a k) = true) : (t == b l) = false := by
  rw [Session.atom_beq_true h]; rfl

theorem binary_ne_atom_key {t : Term} {k l : String} (h : (t == b k) = true) : (t == a l) = false := by
  rw [text_beq_eq h]; rfl

theorem term_get_put_atom (m v : Term) (k l : String) : (m.put (b k) v).get (a l) = m.get (a l) := by
  cases m with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, b, atom_ne_text]
    rw [Session.find?_filter_of_imp]
    intro e he
    simp [atom_ne_binary_key he]
  | _ => simp [Term.put, Term.get, b, atom_ne_text]

theorem term_get_removeKey_atom (m : Term) {k l : String} (h : k ≠ l) :
    (removeKey m (a k)).get (a l) = m.get (a l) := by
  cases m with
  | map entries =>
    simp only [removeKey, Term.get]
    rw [Session.find?_filter_of_imp]
    intro e he
    rw [Session.atom_beq_true he, bne, Session.atom_beq_ne (Ne.symm h)]; rfl
  | _ => rfl

theorem term_get_removeKey_text (m : Term) (k l : String) :
    (removeKey m (a k)).get (b l) = m.get (b l) := by
  cases m with
  | map entries =>
    simp only [removeKey, Term.get]
    rw [Session.find?_filter_of_imp]
    intro e he
    rw [bne, binary_ne_atom_key he]; rfl
  | _ => rfl

theorem term_get_removeKey_atom_same (m : Term) (k : String) :
    ((removeKey m (a k)).put (b k) v).get (a k) = nil := by
  rw [term_get_put_atom]
  cases m with
  | map entries =>
    simp only [removeKey, Term.get]
    rw [List.find?_eq_none.mpr]
    · rfl
    · intro e he
      simp only [List.mem_filter] at he
      intro eq
      rw [Session.atom_beq_true eq, bne, Session.atom_beq_self] at he
      simp at he
  | _ => rfl

theorem field_putField_other (m v : Term) {k l : String} (h : k ≠ l) :
    Provider.field (putField m k v) l = Provider.field m l := by
  simp only [Provider.field, putField, Provider.get, term_get_put_atom, term_get_removeKey_atom _ h,
    get_put_text_other _ _ h, term_get_removeKey_text]

theorem field_putField_same (m v : Term) (k : String) : Provider.field (putField m k v) k = v := by
  simp only [Provider.field, putField, term_get_removeKey_atom_same, truthy_nil, Provider.get]
  simp [get_put_text_same]

theorem pget_putField_same (m v : Term) (k : String) : Provider.get (putField m k v) k = v := by
  simp [putField, Provider.get, get_put_text_same]

theorem coalesce_truthy_or_nil (l : List Term) : (coalesce l).truthy = true ∨ coalesce l = nil := by
  unfold coalesce
  cases hf : l.find? Term.truthy with
  | none => right; rfl
  | some x => left; simpa using List.find?_some hf

theorem callField_putField_self (c : Term) :
    callField (putField c "id" (callField c "id")) "id" = callField c "id" := by
  unfold callField
  rw [pget_putField_same, putField, term_get_removeKey_atom_same]
  rcases coalesce_truthy_or_nil [Provider.get c "id", c.get (a "id")] with h | h
  · rw [coalesce_cons_truthy _ h]
  · rw [h]; rfl

theorem openaiRole_putField (m v : Term) {k : String} (h : k ≠ "role") :
    openaiRole (putField m k v) = openaiRole m := by
  unfold openaiRole; rw [field_putField_other _ _ h]

/-- The role a message has before and after id renaming. -/
def SameRole (m m' : Term) : Prop := openaiRole m' = openaiRole m ∧ Provider.field m' "role" = Provider.field m "role"

theorem SameRole.refl (m : Term) : SameRole m m := ⟨rfl, rfl⟩

theorem SameRole.trans {x y z : Term} (h₁ : SameRole x y) (h₂ : SameRole y z) : SameRole x z :=
  ⟨h₂.1.trans h₁.1, h₂.2.trans h₁.2⟩

theorem SameRole.putField (m v : Term) {k : String} (h : k ≠ "role") : SameRole m (putField m k v) :=
  ⟨openaiRole_putField _ _ h, field_putField_other _ _ h⟩

theorem callId_putField_self (m : Term) : callId (putField m "tool_call_id" (callId m)) = callId m := by
  unfold callId
  rw [field_putField_same, field_putField_other _ _ (by decide)]
  rcases coalesce_truthy_or_nil [Provider.field m "tool_call_id", Provider.field m "tool_use_id"] with h | h
  · rw [coalesce_cons_truthy _ h]
  · rw [h, coalesce_cons_nil, ← h]
    unfold coalesce at h ⊢
    cases hx : (Provider.field m "tool_call_id").truthy <;> simp_all [List.find?_cons]

end VerifiedKernel.ProviderLoop
