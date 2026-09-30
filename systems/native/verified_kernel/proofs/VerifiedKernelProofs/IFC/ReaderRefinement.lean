import VerifiedKernelProofs.IFC.Identity
import VerifiedKernelProofs.IFC.System

namespace VerifiedKernel.IFC.ReaderRefinement
open Data
variable [System.Domain]

/-- Wire identities respect the equality used by the transport. -/
abbrev Key := Identity.Key
abbrev key := Identity.key

structure Mapping where
  atom : Key → System.Atom
  principal : Key → System.Principal
  publicAtom : atom (key (a "public")) = .unrestricted
  privateAtom : atom (key (a "agent_private")) = .runtimePrivate

def Mapping.label (m : Mapping) (wire : Term) : System.Label :=
  (atoms wire).map (fun atom => m.atom (key atom))

def AtomReads (m : Mapping) (w : System.World) (atom : Term) (p : System.Principal) : Prop :=
  System.AtomReads w p (m.atom (key atom))

def AtomFlows (m : Mapping) (w : System.World) (src dst : Term) : Prop :=
  ∀ p, AtomReads m w dst p → AtomReads m w src p

omit [System.Domain] in
theorem key_eq (h : (x == y) = true) : key x = key y := Identity.key_eq h

/-- The resolver supplies primitive facts, not conclusions about the IFC
algorithms. Completeness matters when a destination roster establishes flow. -/
structure FactsSound (m : Mapping) (w : System.World) (facts : Term) : Prop where
  member_sound : ∀ atom xs revision p,
    membership facts atom = .tuple [a "members", xs, revision] →
    contains (setValues xs) (authority p) = true →
    AtomReads m w atom (m.principal (key (authority p)))
  members_complete : ∀ atom,
    isSet (members facts atom) = true →
    ∀ p, AtomReads m w atom p →
      ∃ wire ∈ setValues (members facts atom), m.principal (key (authority wire)) = p
  internal_placement : ∀ p connect,
    placement facts p connect = a "internal" →
    AtomReads m w (.tuple [a "space", connect]) (m.principal (key (authority p)))
  within_edge : ∀ child, (within facts child == nil) = false →
    AtomFlows m w (within facts child) child

omit [System.Domain] in
theorem contains_witness (h : contains xs x = true) :
    ∃ y ∈ xs, key y = key x := by
  obtain ⟨y, member, equal⟩ := List.any_eq_true.mp h
  exact ⟨y, member, key_eq equal⟩

omit [System.Domain] in
theorem allTri_yes (h : allTri xs test = .yes) : ∀ x ∈ xs, test x = .yes := by
  have general : ∀ (xs : List Term) (acc : Tri), xs.foldl (fun acc x => Tri.and acc (test x)) acc = .yes →
      acc = .yes ∧ ∀ x ∈ xs, test x = .yes := by
    intro xs
    induction xs with
    | nil => intro acc h; exact ⟨h, by simp⟩
    | cons x rest ih =>
      intro acc h
      obtain ⟨both, tail⟩ := ih _ h
      have first : acc = .yes ∧ test x = .yes := by
        cases acc <;> cases he : test x <;> simp_all [Tri.and]
      exact ⟨first.1, by simpa using And.intro first.2 tail⟩
  exact (general xs .yes h).2

omit [System.Domain] in
theorem anyTri_yes (h : anyTri xs test = .yes) : ∃ x ∈ xs, test x = .yes := by
  have general : ∀ (xs : List Term) (acc : Tri), xs.foldl (fun acc x => Tri.or acc (test x)) acc = .yes →
      acc = .yes ∨ ∃ x ∈ xs, test x = .yes := by
    intro xs
    induction xs with
    | nil => intro acc h; exact Or.inl h
    | cons x rest ih =>
      intro acc h
      rcases ih _ h with first | later
      · have either : acc = .yes ∨ test x = .yes := by
          cases acc <;> cases he : test x <;> simp_all [Tri.or]
        rcases either with yes | yes
        · exact Or.inl yes
        · exact Or.inr ⟨x, by simp, yes⟩
      · obtain ⟨y, member, yes⟩ := later
        exact Or.inr ⟨y, by simp [member], yes⟩
  rcases general xs .no h with impossible | result
  · contradiction
  · exact result

theorem member_yes (sound : FactsSound m w facts) (h : member facts (authority p) atom = .yes) :
    AtomReads m w atom (m.principal (key (authority p))) := by
  unfold member at h
  split at h
  · rename_i xs rev hm
    apply sound.member_sound atom xs rev p hm
    simpa [Tri.ofBool] using h
  · contradiction

theorem readerAtom_yes (sound : FactsSound m w facts) (h : readerAtom p atom facts = .yes) :
    AtomReads m w atom (m.principal (key (authority p))) := by
  unfold readerAtom at h
  split at h
  · simp [AtomReads, m.publicAtom, System.AtomReads]
  · contradiction
  · rename_i connect
    split at h
    · apply sound.internal_placement; assumption
    · contradiction
    · exact member_yes sound h
  · exact member_yes sound h

theorem withinWalk_sound (sound : FactsSound m w facts)
    (h : withinWalk fuel child ancestor facts = true) : AtomFlows m w ancestor child := by
  induction fuel generalizing child with
  | zero => simp [withinWalk] at h
  | succ fuel ih =>
    simp only [withinWalk] at h
    split at h
    · contradiction
    · rename_i present
      have edge := sound.within_edge child (by simpa using present)
      split at h
      · rename_i equal
        have eqKey := key_eq equal
        simpa [AtomFlows, AtomReads, eqKey] using edge
      · exact fun p hp => ih h p (edge p hp)

theorem atomSubset_yes (sound : FactsSound m w facts)
    (h : atomSubset dst src facts = .yes) : AtomFlows m w src dst := by
  unfold atomSubset at h
  split at h
  · rename_i shortcut
    have cases' : (dst == src) = true ∨ (src == a "public") = true ∨
        (dst == a "agent_private") = true := by simpa [Bool.or_eq_true, or_assoc] using shortcut
    rcases cases' with same | publicAtom | privateH
    · have eqKey := key_eq same
      simp [AtomFlows, AtomReads, eqKey]
    · have eqKey := key_eq publicAtom
      simp [AtomFlows, AtomReads, eqKey, m.publicAtom, System.AtomReads]
    · have eqKey := key_eq privateH
      simp [AtomFlows, AtomReads, eqKey, m.privateAtom, System.AtomReads]
  · split at h
    · contradiction
    · split at h
      · exact withinWalk_sound sound (by assumption)
      · split at h
        · contradiction
        · dsimp only at h
          split at h
          · rename_i known
            intro p hp
            obtain ⟨wire, present, same⟩ := sound.members_complete dst known p hp
            rw [← same]
            exact readerAtom_yes sound (allTri_yes h wire present)
          · split at h <;> contradiction

theorem reads_label : System.Reads w p (m.label wire) ↔
    ∀ atom ∈ atoms wire, AtomReads m w atom p := by
  simp [System.Reads, Mapping.label, AtomReads]

theorem reader_yes (sound : FactsSound m w facts) (h : reader p source facts = .yes) :
    System.Reads w (m.principal (key (authority p))) (m.label source) := by
  apply reads_label.mpr
  intro atom present
  exact readerAtom_yes sound (allTri_yes h atom present)

theorem subset_reads {m : Mapping} (subset : subset (atoms src) (atoms dst) = true)
    (readable : System.Reads w p (m.label dst)) : System.Reads w p (m.label src) := by
  apply reads_label.mpr
  intro atom member
  obtain ⟨other, present, same⟩ := contains_witness (List.all_eq_true.mp subset atom member)
  have reads := reads_label.mp readable other present
  simpa [AtomReads, same] using reads

theorem public_reads {m : Mapping} (publicAtom : publicLabel src = true) : System.Reads w p (m.label src) := by
  have subset : subset (atoms src) [a "public"] = true := (Bool.and_eq_true_iff.mp publicAtom).1
  apply reads_label.mpr
  intro atom member
  obtain ⟨other, present, same⟩ := contains_witness (List.all_eq_true.mp subset atom member)
  have eq : other = a "public" := List.mem_singleton.mp present
  subst other
  simp [AtomReads, ← same, m.publicAtom, System.AtomReads]

theorem readersSubset_yes (sound : FactsSound m w facts)
    (h : readersSubset dst src facts = .yes) : System.Flows w (m.label src) (m.label dst) := by
  unfold readersSubset at h
  split at h
  · rename_i shortcut
    have cases' : restricted dst src = true ∨ publicLabel src = true ∨ noHuman dst = true := by
      simpa [Bool.or_eq_true, or_assoc] using shortcut
    rcases cases' with restricted | publicAtom | privateH
    · have either : subset (atoms src) (atoms dst) = true ∨ publicLabel src = true := by
        simpa [IFC.restricted] using restricted
      rcases either with subset | publicAtom
      · exact fun _ h => subset_reads subset h
      · exact fun _ _ => public_reads publicAtom
    · exact fun _ _ => public_reads publicAtom
    · obtain ⟨atom, present, same⟩ := contains_witness privateH
      intro p readable
      have impossible := reads_label.mp readable atom present
      simp [AtomReads, same, m.privateAtom, System.AtomReads] at impossible
  · intro p readable
    apply reads_label.mpr
    intro atom present
    obtain ⟨dest, member, yes⟩ := anyTri_yes (allTri_yes h atom present)
    exact atomSubset_yes sound yes p (reads_label.mp readable dest member)

end VerifiedKernel.IFC.ReaderRefinement
