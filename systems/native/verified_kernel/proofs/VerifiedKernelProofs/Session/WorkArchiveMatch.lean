import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkValueSemantics
import VerifiedKernel.Session.ArchiveMatch
import VerifiedKernel.Dispatch

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

local instance : LawfulBEq ByteArray where
  eq_of_beq := by
    intro left right same
    exact ByteArray.ext (eq_of_beq same)
  rfl := by
    intro value
    change (value.data == value.data) = true
    exact beq_self_eq_true _

theorem archive_match_registered :
    lookupOp queryTable (a "archive_match_prefix") = some ArchiveMatch.check := rfl

theorem archive_match_dispatch {s args result : Term} {j r : List Term}
    (admitted : Schema.admissible (list j) = true)
    (stable : settled r = true)
    (h : ArchiveMatch.check s args j = .ok (result, r)) :
    SessionDomain.dispatch (some s)
      (.tuple [i 1, a "session", i 1, a "query",
        .tuple [a "archive_match_prefix", args, list j]]) =
      (some s, .tuple [i 1, a "ok", .tuple [a "value", result]]) := by
  change (if Schema.admissible (list j) then
    (some s, Term.tuple [i 1, a "ok", (detach (runOp (a "query") (a "archive_match_prefix")
      args ArchiveMatch.check s j)).2]) else _) = _
  simp only [admitted, ↓reduceIte, runOp, h, stable]
  rfl

theorem archive_match_success {state : Term} {landed window j r : List Term}
    (h : ArchiveMatch.check state (.tuple [list landed, list window]) j = .ok (a "ok", r)) :
    ∃ bytes rest,
      observe (ArchiveMatch.request landed window) j =
        .ok (list [.binary bytes, .binary bytes], rest) ∧ landed.length ≤ window.length := by
  unfold ArchiveMatch.check at h
  obtain ⟨encoded, rest, observed, h⟩ := bind_ok h
  split at h
  · rename_i left right
    split at h
    · have bad := pure_ok h
      cases bad
    · rename_i equal
      have same : left = right := by simpa using equal
      subst right
      split at h
      · have bad := pure_ok h
        cases bad
      · rename_i bounded
        exact ⟨left, rest, observed, by omega⟩
  · exact (fail_ok h).elim

theorem archive_match_message_unchanged {record : Term}
    (kind : record.get (a "kind") = b "message") : ArchiveMatch.canonical record = record := by
  simp only [ArchiveMatch.canonical, kind, show (b "message" == b "fact") = false from rfl,
    Bool.false_and, Bool.false_eq_true, ↓reduceIte]

theorem archive_match_kind_unchanged (record : Term) :
    (ArchiveMatch.canonical record).get (a "kind") = record.get (a "kind") := by
  unfold ArchiveMatch.canonical
  dsimp only
  split
  · split
    · exact get_put_other _ _ (by decide)
    · rfl
  · rfl

namespace ValueSemantics

/-- Codec faithfulness is the trusted primitive. Equal encodings cannot change a fact. -/
theorem archive_match_encoded_prefix {state : Term} {landed window j r rest : List Term}
    (encode : Term → ByteArray) (decode : ByteArray → Term)
    (codec : ∀ value ∈
      [list ((landed.take window.length).map ArchiveMatch.canonical),
       list ((window.take landed.length).map ArchiveMatch.canonical)],
      Equivalent value (decode (encode value)))
    (observed : observe (ArchiveMatch.request landed window) j = .ok
      (list [.binary (encode (list ((landed.take window.length).map ArchiveMatch.canonical))),
        .binary (encode (list ((window.take landed.length).map ArchiveMatch.canonical)))], rest))
    (h : ArchiveMatch.check state (.tuple [list landed, list window]) j = .ok (a "ok", r)) :
    landed.length ≤ window.length ∧
      Equivalent (list (landed.map ArchiveMatch.canonical))
        (list ((window.take landed.length).map ArchiveMatch.canonical)) := by
  obtain ⟨bytes, remaining, read, bound⟩ := archive_match_success h
  rw [observed] at read
  have same : encode (list ((landed.take window.length).map ArchiveMatch.canonical)) =
      encode (list ((window.take landed.length).map ArchiveMatch.canonical)) := by
    simp only [Except.ok.injEq, Prod.mk.injEq, Data.list, Term.list.injEq, List.cons.injEq,
      Term.binary.injEq, and_true] at read
    exact read.1.1.trans read.1.2.symm
  refine ⟨bound, ?_⟩
  have first := codec (list ((landed.take window.length).map ArchiveMatch.canonical)) (by simp)
  have last := codec (list ((window.take landed.length).map ArchiveMatch.canonical)) (by simp)
  rw [same] at first
  have equivalent := first.trans last.symm
  simpa only [List.take_of_length_le bound] using equivalent

theorem archive_match_message_fact {landed window : List Term} {expected : Term}
    (same : Equivalent (list (landed.map ArchiveMatch.canonical))
      (list ((window.take landed.length).map ArchiveMatch.canonical)))
    (member : expected ∈ window.take landed.length)
    (kind : expected.get (a "kind") = b "message") :
    ∃ record ∈ landed, Equivalent expected record := by
  have shape := same.symm.shape
  have length := Shape.list.inj shape
  have pointwise (index : Nat) := same.symm.access (.index index)
  have present : expected ∈ (window.take landed.length).map ArchiveMatch.canonical := by
    rw [← archive_match_message_unchanged kind]
    exact List.mem_map.mpr ⟨expected, member, rfl⟩
  obtain ⟨canonical, found, equivalent⟩ := list_member length pointwise present
  obtain ⟨record, member, canonicalEq⟩ := List.mem_map.mp found
  subst canonical
  have kindSame := equivalent.get (a "kind")
  rw [kind] at kindSame
  have rawKind : record.get (a "kind") = b "message" := by
    rw [← archive_match_kind_unchanged record]
    exact kindSame.binary
  rw [archive_match_message_unchanged rawKind] at equivalent
  exact ⟨record, member, equivalent⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
