import VerifiedKernelProofs.IFC.SelectionRefinement
import VerifiedKernelProofs.IFC.Transfer

namespace VerifiedKernel.IFC.SemanticRefinement
open Data Identity WireSemantics
local instance : System.Domain := domain

def evidenceClause : Term → Term
  | .tuple [_, clause] => clause
  | _ => nil

def admissions (sources entries : List Term) : List System.Admission :=
  (sources.zip entries).map (fun pair => ⟨item pair.1, clause (evidenceClause pair.2)⟩)

theorem evidence_items {sources entries : List Term}
    (h : DecisionContract.EvidenceSources rawEffect rawActivation p facts sources entries) :
    (admissions sources entries).map System.Admission.item = sources.map item := by
  induction h with
  | nil => rfl
  | cons _ _ ih =>
    simpa only [admissions, List.zip_cons_cons, List.map_cons] using congrArg (List.cons _) ih

theorem evidence_authorized {sources entries : List Term}
    (sound : ReaderRefinement.FactsSound mapping w facts)
    (snapshot : ReceiptSnapshot facts receipts)
    (valid : ∀ raw ∈ sources, labelValid (f raw "label") = true)
    (hp : policyValid (f facts "policy") = true)
    (hn : f facts "now" = .integer clock) (nonnegative : 0 ≤ clock)
    (requester : principal p = (activation rawActivation).requester)
    (h : DecisionContract.EvidenceSources rawEffect rawActivation p facts sources entries) :
    ∀ entry ∈ admissions sources entries,
      System.SourceAuthorized w (policy (f facts "policy")) (activation rawActivation)
        (effect rawEffect) entry.item.label receipts clock.toNat entry.clause := by
  induction h with
  | nil => simp [admissions]
  | @cons source entry sources entries head tail ih =>
    obtain ⟨rawClause, rfl, authorized⟩ := head
    intro entry present
    simp only [admissions, List.zip_cons_cons, List.map_cons, List.mem_cons] at present
    rcases present with same | later
    · subst entry
      exact source_authorized sound snapshot (valid source (by simp)) hp hn nonnegative requester authorized
    · exact ih (fun raw member => valid raw (by simp [member])) entry later

theorem evidence_receipt {sources entries : List Term} {id : System.ReceiptId}
    (h : DecisionContract.EvidenceSources rawEffect rawActivation p facts sources entries)
    (valid : ∀ raw ∈ setValues (f facts "receipts"), (f raw "id").isBinary = true)
    (present : entry ∈ admissions sources entries) (used : entry.clause = .receipt id) :
    ∃ bytes rawEntry, rawEntry ∈ entries ∧ Transfer.receiptId rawEntry = some bytes ∧
      key (.binary bytes) = id := by
  induction h with
  | nil => simp [admissions] at present
  | @cons source rawEntry sources entries head tail ih =>
    obtain ⟨rawClause, rfl, authorized⟩ := head
    simp only [admissions, List.zip_cons_cons, List.map_cons, List.mem_cons] at present
    rcases present with same | later
    · subst entry
      cases authorized with
      | flow => simp [evidenceClause, clause, a] at used
      | inPlace => simp [evidenceClause, clause, a] at used
      | instruction => simp [evidenceClause, clause, a] at used
      | receipt r _ _ _ member _ _ =>
        have binary := valid r member
        cases hid : f r "id" <;> simp only [hid, Term.isBinary] at binary <;> try contradiction
        rename_i bytes
        refine ⟨bytes, .tuple [f source "ref", .tuple [a "receipt", .binary bytes]], by simp, rfl, ?_⟩
        simpa [evidenceClause, clause, a, hid] using used
    · obtain ⟨bytes, raw, member, isReceipt, equal⟩ := ih later
      exact ⟨bytes, raw, by simp [member], isReceipt, equal⟩

theorem resolved_subset (present : request ∈ xs)
    (h : DecisionContract.Resolves rawEffect request xs sources) : ∀ raw ∈ sources, raw ∈ xs := by
  rcases h with ⟨_, rfl⟩ | ⟨_, selected, selectedH, rfl⟩
  · intro raw member
    rcases List.mem_cons.mp (SelectionRefinement.dedupe_subset member) with same | old
    · exact same ▸ present
    · exact old
  · intro raw member
    exact SelectionRefinement.selected_subset selectedH raw (SelectionRefinement.dedupe_subset member)

theorem evidence_entries {entries : List Term}
    (h : evidence = .map [
      (a "__struct__", a "Elixir.SalixIFC.Evidence"),
      (a "request", request), (a "requester", requester),
      (a "destination", destination), (a "sources", list entries),
      (a "membership_revisions", revisions)]) : values (f evidence "sources") = entries := by
  subst evidence
  rfl

/-- Full executable admission refines the independent system rules. Premises
describe the external authority snapshot and the host command-scope gate, not
the correctness of an IFC helper or its choice of clause. -/
theorem decideChecked_system
    (allowed : decideChecked rawEffect rawActivation rawItems facts = .ok evidence)
    (sound : ReaderRefinement.FactsSound mapping w facts)
    (snapshot : ReceiptSnapshot facts receipts)
    (scope : commandScope) :
    ∃ request clock sources entries revisions,
      request ∈ values rawItems ∧ f facts "now" = .integer clock ∧
      evidence = .map [
        (a "__struct__", a "Elixir.SalixIFC.Evidence"),
        (a "request", f rawEffect "request"), (a "requester", authority (f request "principal")),
        (a "destination", f rawEffect "destination"), (a "sources", list entries),
        (a "membership_revisions", revisions)] ∧
      DecisionContract.Resolves rawEffect request (values rawItems) sources ∧
      DecisionContract.EvidenceSources rawEffect rawActivation (f request "principal") facts sources entries ∧
      System.Authorized w (policy (f facts "policy")) ((values rawItems).map item)
        (activation rawActivation) (effect rawEffect) receipts clock.toNat
        (gates rawEffect (f request "principal") facts commandScope)
        (admissions sources entries) := by
  obtain ⟨valid, unique, request, present, requestH, writer, sources, resolved,
    publicH, entries, revisions, _, admitted, wireEvidence⟩ := FullRefinement.decideChecked_sound allowed
  rcases valid with ⟨_, _, _, _, _, effectH, _, _, _, itemsH, _, factsH⟩
  have refValid : ∀ raw ∈ values rawItems, (f raw "ref").isBinary = true := by
    intro raw member
    have h := List.all_eq_true.mp itemsH raw member
    simp only [itemValid, Bool.and_eq_true] at h
    exact h.1.1.1.2
  have labelValidH : ∀ raw ∈ values rawItems, labelValid (f raw "label") = true := by
    intro raw member
    have h := List.all_eq_true.mp itemsH raw member
    simp only [itemValid, Bool.and_eq_true] at h
    exact h.1.1.2
  have destinationValid : labelValid (f rawEffect "destination") = true := by
    simp only [effectValid, Bool.and_eq_true] at effectH
    exact effectH.1.1.1.2
  simp only [factsValid, Bool.and_eq_true] at factsH
  obtain ⟨⟨⟨⟨⟨⟨⟨_, hp⟩, nowH⟩, _⟩, _⟩, _⟩, _⟩, _⟩ := factsH
  have time : ∃ clock, f facts "now" = .integer clock ∧ 0 ≤ clock := by
    cases hn : f facts "now" <;> simp_all
  obtain ⟨clock, hn, nonnegative⟩ := time
  have requester : principal (f request "principal") = (activation rawActivation).requester :=
    key_eq requestH.2.2.2.2
  have semanticSources := SelectionRefinement.resolves
    (SelectionRefinement.unique_coherent unique refValid) present resolved
  have semanticEvidence := evidence_authorized sound snapshot
    (fun raw member => labelValidH raw (resolved_subset present resolved raw member))
    hp hn nonnegative requester admitted
  have semanticGates := gates_hold writer publicH destinationValid requester scope
  have semanticRequest := request_authorized present requestH
  refine ⟨request, clock, sources, entries, revisions, present, hn, wireEvidence,
    resolved, admitted, semanticRequest, ?_, ?_, semanticEvidence⟩
  · simpa only [evidence_items admitted] using semanticGates
  · simpa only [evidence_items admitted] using semanticSources

end VerifiedKernel.IFC.SemanticRefinement
