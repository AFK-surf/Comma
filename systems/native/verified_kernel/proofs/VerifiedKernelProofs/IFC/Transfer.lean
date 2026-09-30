import VerifiedKernel.IFC.Transfer
import VerifiedKernelProofs.IFC.Identity

namespace VerifiedKernel.IFC.Transfer
open Data

local instance : LawfulBEq ByteArray where
  eq_of_beq := Identity.bytes_eq
  rfl := by intro bytes; change (bytes.data == bytes.data) = true; exact beq_self_eq_true _

theorem ids_cover {id : ByteArray} (h : entry ∈ values (f evidence "sources")) (receipt : receiptId entry = some id) :
    id ∈ ids evidence := by
  apply List.mem_eraseDups.mpr
  exact List.mem_filterMap.mpr ⟨entry, h, receipt⟩

theorem cursor_roundtrip (pending : List ByteArray) :
    (pending.map Term.binary).mapM bytes = some pending := by
  induction pending with
  | nil => rfl
  | cons id pending ih => simp [List.mapM_cons, bytes, ih]

theorem resume_success {pending : List ByteArray} :
    resume (.list (pending.map Term.binary)) (.tuple [a "ok", a "true"]) = next pending := by
  simp only [resume, cursor_roundtrip, a]

theorem resume_used {pending : List ByteArray} :
    resume (.list (pending.map Term.binary)) (.tuple [a "ok", a "false"]) =
      .tuple [a "error", a "receipt_already_used"] := by
  simp only [resume, cursor_roundtrip, a]

theorem resume_unavailable {pending : List ByteArray} :
    resume (.list (pending.map Term.binary)) (.tuple [a "error", reason]) =
      .tuple [a "error", a "receipt_unavailable"] := by
  simp only [resume, cursor_roundtrip, a]
  split <;> simp_all

/-- A driver trace records the store observations actually passed to resume.
Only a successful claim advances the continuation. -/
inductive Completes : Term → List (ByteArray × Term) → Prop where
  | done : Completes (a "ok") []
  | claim {id : ByteArray} {cursor observation : Term}
      (tail : Completes (resume cursor observation) observations) :
      Completes (.tuple [a "consume", .binary id, cursor]) ((id, observation) :: observations)

theorem completes_shape (h : Completes result observations) :
    result = a "ok" ∨ ∃ id cursor, result = .tuple [a "consume", .binary id, cursor] := by
  cases h with
  | done => exact Or.inl rfl
  | claim => exact Or.inr ⟨_, _, rfl⟩

theorem complete_claims (complete : Completes (next pending) observations) :
    ∀ id ∈ pending, (id, .tuple [a "ok", a "true"]) ∈ observations := by
  induction pending generalizing observations with
  | nil => simp
  | cons id pending ih =>
    cases complete with
    | @claim _ _ observation observations tail =>
      simp only [resume, cursor_roundtrip] at tail
      split at tail
      · intro other member
        rcases List.mem_cons.mp member with same | later
        · simp [same]
        · exact List.mem_cons_of_mem _ (ih tail other later)
      · have shape := completes_shape tail; simp [a] at shape
      · have shape := completes_shape tail; simp [a] at shape

end VerifiedKernel.IFC.Transfer
