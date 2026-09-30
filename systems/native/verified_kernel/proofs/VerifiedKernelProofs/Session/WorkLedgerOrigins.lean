import VerifiedKernelProofs.Session.WorkLedgerInput
import VerifiedKernelProofs.Session.WorkResidentSafety

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def IdentityPresent (ledger key : Term) : Prop := (ledger.get (a "map")).has key = true

theorem identity_present_or_absent (ledger key : Term) : IdentityPresent ledger key ∨ IdentityAbsent ledger key := by
  cases value : (ledger.get (a "map")).has key with
  | true => exact Or.inl value
  | false => exact Or.inr value

theorem identity_origin_of_absence {before after key : Term} {keys : List Term}
    (preserves : IdentityAbsent before key → (∀ inserted ∈ keys, (inserted == key) = false) → IdentityAbsent after key)
    (present : IdentityPresent after key) :
    IdentityPresent before key ∨ ∃ inserted ∈ keys, (inserted == key) = true := by
  classical
  rcases identity_present_or_absent before key with old | absent
  · exact Or.inl old
  · right
    apply Classical.byContradiction
    intro missing
    have different : ∀ inserted ∈ keys, (inserted == key) = false := by
      intro inserted member
      cases equal : (inserted == key) with
      | false => rfl
      | true => exact (missing ⟨inserted, member, equal⟩).elim
    have gone := preserves absent different
    unfold IdentityAbsent at gone
    unfold IdentityPresent at present
    rw [gone] at present
    contradiction

theorem addDedupe_origin {before after key : Term} {keys journal rest : List Term}
    (call : addDedupe before keys journal = .ok (after, rest)) (present : IdentityPresent after key) :
    IdentityPresent before key ∨ ∃ inserted ∈ keys, (inserted == key) = true :=
  identity_origin_of_absence (fun absent different => addDedupe_preserves_absence absent different call) present

/-- All five admitted identity writers derive new ledger members from the keys read by the kernel. -/
theorem admitted_ledger_origin {state event next : Term} {source : ByteArray} {groups : List (List Term)}
    {journal rest before after : List Term}
    (allowed : Command.inputEventAllowed event = true)
    (checked : Command.inputIdentityGroups event before = .ok (groups, after))
    (call : inner state event journal = .ok (next, rest))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) ∨
      ∃ inserted ∈ groups.flatten, (inserted == .binary source) = true :=
  identity_origin_of_absence
    (fun absent different => admitted_inner_checked_ledger_absent allowed checked different absent call) present

theorem resident_batch_ledger_absent {state next : Term} {source : ByteArray} {events : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ events, IdentityCheckAvoids event source)
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source)) :
    IdentityAbsent (next.get (a "input_dedupe")) (.binary source) := by
  induction execution with
  | nil => exact absent
  | cons head tail ih =>
    exact ih (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => allowed event (List.mem_cons_of_mem _ member))
      (fun event member => checked event (List.mem_cons_of_mem _ member))
      (resident_input_ledger_absent (canonical _ List.mem_cons_self) (allowed _ List.mem_cons_self)
        (checked _ List.mem_cons_self) absent head)

def IdentitySource (event : Term) (source : ByteArray) : Prop :=
  ∃ groups journal rest, Command.inputIdentityGroups event journal = .ok (groups, rest) ∧
    ∃ inserted ∈ groups.flatten, (inserted == .binary source) = true

/-- A successful native batch cannot invent a binary ledger identity outside its executed input writers. -/
theorem resident_batch_identity_origin {state next : Term} {source : ByteArray} {events : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ events, ∃ groups journal rest, Command.inputIdentityGroups event journal = .ok (groups, rest))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) ∨
      ∃ event ∈ events, IdentitySource event source := by
  classical
  rcases identity_present_or_absent (state.get (a "input_dedupe")) (.binary source) with old | absent
  · exact Or.inl old
  · right
    apply Classical.byContradiction
    intro missing
    have avoids : ∀ event ∈ events, IdentityCheckAvoids event source := by
      intro event member
      obtain ⟨groups, journal, rest, call⟩ := checked event member
      refine ⟨groups, journal, rest, call, ?_⟩
      intro inserted included
      cases equal : (inserted == .binary source) with
      | false => rfl
      | true => exact (missing ⟨event, member, groups, journal, rest, call, inserted, included, equal⟩).elim
    have gone := resident_batch_ledger_absent execution canonical allowed avoids absent
    unfold IdentityAbsent at gone
    unfold IdentityPresent at present
    rw [gone] at present
    contradiction

end VerifiedKernel.Session.WorkConservation
