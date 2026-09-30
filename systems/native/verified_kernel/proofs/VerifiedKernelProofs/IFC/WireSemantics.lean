import VerifiedKernelProofs.IFC.ReaderRefinement
import VerifiedKernelProofs.IFC.FullRefinement

namespace VerifiedKernel.IFC.WireSemantics
open Data Identity

@[reducible] def domain : System.Domain :=
  ⟨Key, Key, Key, Key, inferInstance, inferInstance, inferInstance, inferInstance⟩
local instance : System.Domain := domain

def atom (id : Key) : System.Atom :=
  if id = key (a "public") then .unrestricted
  else if id = key (a "agent_private") then .runtimePrivate
  else .audience id

def mapping : ReaderRefinement.Mapping where
  atom := atom
  principal := id
  publicAtom := by simp [atom]
  privateAtom := by simp [atom, key, a]

def label (wire : Term) : System.Label := mapping.label wire
def principal (wire : Term) : System.Principal := key (authority wire)

theorem atom_injective (h : atom x = atom y) : x = y := by
  unfold atom at h
  repeat' first | split at h | contradiction
  all_goals simp_all

theorem subset_labels (h : subset (atoms src) (atoms dst) = true) :
    ∀ v ∈ label src, v ∈ label dst := by
  intro v hv
  obtain ⟨wire, member, rfl⟩ := List.mem_map.mp hv
  obtain ⟨other, present, same⟩ := ReaderRefinement.contains_witness (List.all_eq_true.mp h wire member)
  exact List.mem_map.mpr ⟨other, present, congrArg atom same⟩

theorem equal_labels (h : labelEqual src dst = true) : System.LabelEq (label src) (label dst) := by
  obtain ⟨forward, backward⟩ := Bool.and_eq_true_iff.mp h
  exact fun v => ⟨subset_labels forward v, subset_labels backward v⟩

theorem public_label (h : publicLabel src = true) : System.LabelEq (label src) [.unrestricted] := by
  obtain ⟨forward, backward⟩ := Bool.and_eq_true_iff.mp h
  intro v
  constructor
  · intro hv
    obtain ⟨wire, member, rfl⟩ := List.mem_map.mp hv
    obtain ⟨other, present, same⟩ := ReaderRefinement.contains_witness (List.all_eq_true.mp forward wire member)
    have eq := List.mem_singleton.mp present
    subst other
    simp [mapping, ← same, atom]
  · intro hv
    have eq := List.mem_singleton.mp hv
    subst v
    obtain ⟨wire, present, same⟩ := ReaderRefinement.contains_witness
      (List.all_eq_true.mp backward (a "public") (by simp))
    exact List.mem_map.mpr ⟨wire, present, by simp [mapping, same, atom]⟩

def policy (wire : Term) : System.Policy where
  sealed v := ∃ raw ∈ setValues (f wire "sealed_atoms"), atom (key raw) = v
  inPlace := key (f wire "declassification") ∈
    [key (a "in_place_and_receipt"), key (a "trust_requester_instruction")]
  instruction := key (f wire "declassification") = key (a "trust_requester_instruction")
  receipt := key (f wire "declassification") ≠ key (a "none")

theorem unsealed (hv : labelValid source = true) (hp : policyValid rawPolicy = true)
    (h : DecisionContract.Unsealed source rawPolicy) : System.Unsealed (policy rawPolicy) (label source) := by
  have validAtoms : (atoms source).all atomValid = true := (Bool.and_eq_true_iff.mp hv).2
  have validSealed : (setValues (f rawPolicy "sealed_atoms")).all atomValid = true :=
    (Bool.and_eq_true_iff.mp hp).2
  intro v member sealed
  obtain ⟨src, present, rfl⟩ := List.mem_map.mp member
  obtain ⟨other, otherPresent, same⟩ := sealed
  have eqKey := atom_injective same
  have equal := beq_of_key_eq
    (atom_key_valid (List.all_eq_true.mp validSealed other otherPresent))
    (atom_key_valid (List.all_eq_true.mp validAtoms src present)) eqKey
  have yes : contains (setValues (f rawPolicy "sealed_atoms")) src = true :=
    List.any_eq_true.mpr ⟨other, otherPresent, equal⟩
  rw [h src present] at yes
  contradiction

def receipt (wire : Term) : System.Receipt where
  requester := principal (f wire "requester")
  sources := label (f wire "sources")
  destination := label (f wire "destination")
  expires := match f wire "expires_at" with
    | .integer n => some n.toNat
    | _ => none

theorem receipt_covers (hc : receiptCovers r p src dst = true)
    (hv : receiptValidAt r (.integer clock) = true) (hn : 0 ≤ clock) :
    System.Covers (receipt r) (principal p) (label src) (label dst) clock.toNat := by
  have both := Bool.and_eq_true_iff.mp hc
  have requester := (Bool.and_eq_true_iff.mp both.1).1
  have destination := (Bool.and_eq_true_iff.mp both.1).2
  have sources := both.2
  refine ⟨key_eq requester, equal_labels destination, ?_, ?_⟩
  · rcases Bool.or_eq_true_iff.mp sources with restricted | publicH
    · exact Or.inl (subset_labels restricted)
    · exact Or.inr (public_label publicH)
  · intro expiry heq
    simp only [receipt] at heq
    cases hx : f r "expires_at" <;> simp [hx] at heq
    rename_i n
    subst expiry
    have bound : clock < n := by simpa [receiptValidAt, hx] using hv
    omega

theorem reader_sound (sound : ReaderRefinement.FactsSound mapping w facts)
    (h : reader p source facts = .yes) : System.Reads w (principal p) (label source) :=
  ReaderRefinement.reader_yes sound h

theorem flow_sound (sound : ReaderRefinement.FactsSound mapping w facts)
    (h : readersSubset dst src facts = .yes) : System.Flows w (label src) (label dst) :=
  ReaderRefinement.readersSubset_yes sound h

def activation (wire : Term) : System.Activation where
  requester := principal (f wire "requester")
  sourceScope := label (f wire "source_scope")
  consumed := (setValues (f wire "consumed_refs")).map key

def effect (wire : Term) : System.Effect where
  request := key (f wire "request")
  sources := if f wire "sources" == a "context" then .context
    else .explicit ((values (f wire "sources")).map key)
  destination := label (f wire "destination")

def item (wire : Term) : System.Item where
  ref := key (f wire "ref")
  label := label (f wire "label")
  integrity := if f wire "integrity" == a "command" then .command else .data
  principal := if f wire "principal" == nil then none else some (principal (f wire "principal"))

def clause (wire : Term) : System.Clause :=
  match wire with
  | .atom "in_place" => .inPlace
  | .atom "instruction" => .instruction
  | .tuple [.atom "receipt", id] => .receipt (key id)
  | _ => .flow

theorem inplace_allowed (h : inPlaceAllowed rawPolicy = true) : (policy rawPolicy).inPlace := by
  obtain ⟨wire, present, same⟩ := ReaderRefinement.contains_witness h
  change key (f rawPolicy "declassification") ∈
    [a "in_place_and_receipt", a "trust_requester_instruction"].map key
  apply List.mem_map.mpr
  exact ⟨wire, present, same⟩

theorem instruction_allowed (h : instructionAllowed rawPolicy = true) :
    (policy rawPolicy).instruction := key_eq h

theorem receipt_allowed (h : receiptAllowed rawPolicy = true) : (policy rawPolicy).receipt := by
  intro same
  have valid : key (a "none") ≠ .invalid := by simp [key]
  have equal := beq_of_key_eq (by rw [same]; exact valid) valid same
  change (!(f rawPolicy "declassification" == a "none")) = true at h
  rw [equal] at h
  contradiction

/-- Store facts identify records. All coverage and expiry checks are proved
above; this premise is only the authoritative receipt-table snapshot. -/
def ReceiptSnapshot (facts : Term) (receipts : System.ReceiptId → Option System.Receipt) : Prop :=
  ∀ raw ∈ setValues (f facts "receipts"), receipts (key (f raw "id")) = some (receipt raw)

theorem source_authorized
    (sound : ReaderRefinement.FactsSound mapping w facts)
    (snapshot : ReceiptSnapshot facts receipts)
    (hv : labelValid (f source "label") = true)
    (hp : policyValid (f facts "policy") = true)
    (hn : f facts "now" = .integer clock) (nonnegative : 0 ≤ clock)
    (requester : principal p = (activation rawActivation).requester)
    (h : DecisionContract.SourceAuthorized source rawEffect rawActivation p facts rawClause) :
    System.SourceAuthorized w (policy (f facts "policy")) (activation rawActivation)
      (effect rawEffect) (label (f source "label")) receipts clock.toNat (clause rawClause) := by
  cases h with
  | flow h => exact .flow (flow_sound sound h)
  | inPlace hu hr hi he =>
    exact .inPlace (unsealed hv hp hu) (requester ▸ reader_sound sound hr)
      (inplace_allowed hi) (equal_labels he)
  | instruction hu hr hi =>
    exact .instruction (unsealed hv hp hu) (requester ▸ reader_sound sound hr)
      (instruction_allowed hi)
  | receipt r hu hr ha hm ht hc =>
    exact .receipt (unsealed hv hp hu) (requester ▸ reader_sound sound hr)
      (receipt_allowed ha) (snapshot r hm)
      (requester ▸ receipt_covers hc (hn ▸ ht) nonnegative)

theorem request_authorized {rawItems : List Term} (present : request ∈ rawItems)
    (h : DecisionContract.RequestAuthorized rawEffect rawActivation request) :
    System.RequestAuthorized (rawItems.map item) (activation rawActivation) (effect rawEffect) := by
  obtain ⟨href, integrity, nonnil, consumed, requester⟩ := h
  refine ⟨item request, List.mem_map.mpr ⟨request, present, rfl⟩, key_eq href, ?_, ?_, ?_⟩
  · simp [item, integrity]
  · simp [item, nonnil, activation, principal, key_eq requester]
  · obtain ⟨raw, member, same⟩ := ReaderRefinement.contains_witness consumed
    exact List.mem_map.mpr ⟨raw, member, same⟩

theorem public_label_complete (valid : labelValid raw = true)
    (h : System.LabelEq (label raw) [.unrestricted]) : publicLabel raw = true := by
  have validAtoms := (Bool.and_eq_true_iff.mp valid).2
  have publicValid : key (a "public") ≠ .invalid := by simp [key]
  apply Bool.and_eq_true_iff.mpr
  constructor
  · apply List.all_eq_true.mpr
    intro rawAtom present
    have member := (h (atom (key rawAtom))).mp (List.mem_map.mpr ⟨rawAtom, present, rfl⟩)
    have same : atom (key rawAtom) = atom (key (a "public")) := by simpa [atom] using member
    have eqKey := atom_injective same
    exact List.any_eq_true.mpr ⟨a "public", by simp,
      beq_of_key_eq publicValid (atom_key_valid (List.all_eq_true.mp validAtoms rawAtom present)) eqKey.symm⟩
  · apply List.all_eq_true.mpr
    intro rawAtom present
    have eq := List.mem_singleton.mp present
    subst rawAtom
    obtain ⟨wire, member, same⟩ := List.mem_map.mp ((h .unrestricted).mpr (by simp))
    have eqKey := atom_injective (x := key wire) (y := key (a "public"))
      (by simpa only [mapping, atom, ↓reduceIte] using same)
    exact List.any_eq_true.mpr ⟨wire, member,
      beq_of_key_eq (atom_key_valid (List.all_eq_true.mp validAtoms wire member)) publicValid eqKey⟩

def gates (rawEffect p facts : Term) (commandScope : Prop) : System.Gates where
  writers := if f rawEffect "writers" == a "any" then .any
    else if f rawEffect "writers" == a "unknown" then .unknown
    else .members ((setValues (f rawEffect "writers")).map key)
  external := external facts p
  externalMode := if f (f facts "policy") "external_principals" == a "as_internal" then .asInternal
    else if f (f facts "policy") "external_principals" == a "own_thread_only" then .ownThread
    else .deny
  publicMode := if f (f facts "policy") "public_egress" == a "receipt" then .receipt
    else .publicSourcesOnly
  commandScope := commandScope

theorem gates_hold (writer : DecisionContract.WriterAuthorized rawEffect rawActivation p facts)
    (publicH : DecisionContract.PublicAuthorized rawEffect facts sources)
    (validDestination : labelValid (f rawEffect "destination") = true)
    (requester : principal p = (activation rawActivation).requester) (scope : commandScope) :
    (gates rawEffect p facts commandScope).Hold (activation rawActivation) (effect rawEffect)
      (sources.map item) := by
  obtain ⟨externalH, writerH⟩ := writer
  refine ⟨?_, ?_, ?_, scope⟩
  · by_cases anyH : (f rawEffect "writers" == a "any") = true
    · simp [gates, anyH]
    · simp only [gates, anyH]
      rcases writerH with anyH | ⟨known, member⟩
      · contradiction
      · simp only [known, Bool.false_eq_true, ↓reduceIte]
        obtain ⟨raw, present, same⟩ := ReaderRefinement.contains_witness member
        exact List.mem_map.mpr ⟨raw, present, same.trans requester⟩
  · rcases externalH with internalH | internalMode | ⟨ownMode, equal⟩
    · exact Or.inl internalH
    · exact Or.inr (by simp [gates, internalMode])
    · apply Or.inr
      by_cases internalH : (f (f facts "policy") "external_principals" == a "as_internal") = true
      · simp [gates, internalH]
      · simp only [gates, internalH, ownMode, ↓reduceIte]
        exact equal_labels equal
  · by_cases receiptH : (f (f facts "policy") "public_egress" == a "receipt") = true
    · simp [gates, receiptH]
    · simp only [gates, receiptH]
      intro destination decoded present
      obtain ⟨raw, member, rfl⟩ := List.mem_map.mp present
      rcases publicH with notPublic | receiptH | publicSources
      · have yes := public_label_complete validDestination destination
        rw [notPublic] at yes
        contradiction
      · contradiction
      · exact public_label (publicSources raw member)

end VerifiedKernel.IFC.WireSemantics
