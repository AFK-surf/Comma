import VerifiedKernelProofs.IFC.DecisionContract
import VerifiedKernelProofs.IFC.SystemRefinement
import Init.Data.List.Sort.Lemmas

namespace VerifiedKernel.IFC.FullRefinement
open Data DecisionContract

private theorem bind_ok (x : α) (k : α → Except ε β) : (Except.ok x >>= k) = k x := rfl
private theorem bind_error (err : ε) (k : α → Except ε β) :
    (Except.error err >>= k) = .error err := rfl
private theorem map_ok (x : α) (k : α → β) : k <$> (Except.ok x : Except ε α) = .ok (k x) := rfl
private theorem map_error (err : ε) (k : α → β) : k <$> (Except.error err : Except ε α) = .error err := rfl
private theorem pure_ok (x : α) : (pure x : Except ε α) = .ok x := rfl
private theorem throw_error (err : ε) : (throw err : Except ε α) = .error err := rfl
attribute [local simp] bind_ok bind_error map_ok map_error pure_ok throw_error

theorem collectSources_ok (check : Term → Check Term) (sources : List Term) (entries : List Term) :
    collectSources check sources = .ok entries ↔ sources.mapM check = .ok entries := by
  induction sources generalizing entries with
  | nil => simp [collectSources]
  | cons source rest ih =>
    cases first : check source with
    | error why => simp [collectSources, first]
    | ok entry =>
      simp only [List.mapM_cons, first, bind_ok]
      simp only [collectSources, List.map_cons, first, List.filterMap_cons]
      split <;> cases tail : rest.mapM check <;> simp_all [collectSources]
      · rename_i result condition
        have same := (ih result).mpr rfl
        rw [same]
      · rename_i result condition
        have impossible := (ih result).mpr rfl
        split at impossible <;> simp_all
        grind

theorem unique_refs_aux_sound (h : checkUniqueRefsAux seen items = .ok ()) :
    UniqueRefs items ∧ ∀ ref ∈ seen, ∀ item ∈ items, (ref == f item "ref") = false := by
  induction items generalizing seen with
  | nil => exact ⟨.nil, by simp⟩
  | cons item rest ih =>
    simp only [checkUniqueRefsAux] at h
    split at h
    · contradiction
    · rename_i absent
      obtain ⟨pairwise, fresh⟩ := ih h
      refine ⟨.cons (fresh _ (by simp)) pairwise, ?_⟩
      intro ref member other present
      rcases List.mem_cons.mp present with same | later
      · subst other
        have absent' : ∀ ref ∈ seen, (ref == f item "ref") = false := by
          simpa [contains] using absent
        exact absent' ref member
      · exact fresh ref (by simp [member]) other later

theorem unique_refs_sound (h : checkUniqueRefs items = .ok ()) : UniqueRefs items :=
  (unique_refs_aux_sound h).1

theorem validate_sound (h : validate effect activation items facts = .ok ()) :
    ValidInputs effect activation items facts := by
  unfold validate at h
  split at h <;> simp_all
  split at h <;> simp_all
  split at h <;> simp_all
  split at h <;> simp_all
  split at h <;> simp_all
  simp_all [ValidInputs]

theorem request_check_sound (h : requestCheck request activation = .ok ()) :
    (f request "integrity" == a "command") = true ∧
    (f request "principal" == nil) = false ∧
    contains (setValues (f activation "consumed_refs")) (f request "ref") = true ∧
    (authority (f request "principal") == authority (f activation "requester")) = true := by
  unfold requestCheck at h
  split at h <;> simp_all [bne]
  split at h <;> simp_all
  split at h <;> simp_all

theorem resolve_request_sound (h : resolveRequest effect activation items = .ok request) :
    request ∈ items ∧ RequestAuthorized effect activation request := by
  unfold resolveRequest at h
  cases found : items.find? (fun item => f item "ref" == f effect "request") with
  | none => simp [found] at h
  | some item =>
    cases checked : requestCheck item activation with
    | error why => simp [found, checked] at h
    | ok result =>
      cases result
      simp [found, checked] at h
      subst request
      have matched := List.find?_some found
      exact ⟨List.mem_of_find?_eq_some found, matched, request_check_sound checked⟩

theorem writer_sound (h : checkWriter effect activation p facts = .ok ()) :
    WriterAuthorized effect activation p facts := by
  unfold checkWriter at h
  dsimp only at h
  split at h <;> simp_all [WriterAuthorized] <;> grind

theorem public_sound (h : checkPublic effect items facts = .ok ()) :
    PublicAuthorized effect facts items := by
  unfold checkPublic at h
  split at h
  · simp_all [PublicAuthorized]
    grind
  · split at h
    · rename_i found
      right; right
      simpa using List.find?_eq_none.mp found
    · contradiction

theorem receipt_sound {id : Term} (h : findReceipt facts p src dst = some id) :
    ∃ r ∈ setValues (f facts "receipts"), receiptValidAt r (f facts "now") = true ∧
      receiptCovers r p src dst = true ∧ f r "id" = id := by
  unfold findReceipt at h
  obtain ⟨r, found, rid⟩ := Option.map_eq_some_iff.mp h
  have mem := List.mem_of_find?_eq_some found
  have valid := List.find?_some found
  simp only [Bool.and_eq_true] at valid
  exact ⟨r, by simpa using mem, valid.1, valid.2, rid⟩

theorem unsealed_sound (h : sealed source policy = false) : Unsealed source policy := by
  simpa [sealed, Unsealed] using h

theorem source_sound (h : admitSource source effect activation p facts = .ok entry) :
    ∃ clause, entry = .tuple [f source "ref", clause] ∧
      SourceAuthorized source effect activation p facts clause := by
  unfold admitSource at h
  dsimp only at h
  split at h
  · rename_i admitted selected
    simp only [Except.ok.injEq] at h
    subst entry
    refine ⟨admitted.term, rfl, ?_⟩
    have hs := SystemRefinement.selectAdmission_sound selected
    cases admitted with
    | flow => exact .flow hs
    | inPlace =>
      obtain ⟨unlocked, readable, inPlace⟩ := hs
      have both : labelEqual (f effect "destination") (f activation "source_scope") = true ∧
          inPlaceAllowed (f facts "policy") = true := by simpa using inPlace
      exact .inPlace (unsealed_sound unlocked) readable both.2 both.1
    | instruction =>
      obtain ⟨unlocked, readable, instruction⟩ := hs
      exact .instruction (unsealed_sound unlocked) readable instruction
    | receipt id =>
      obtain ⟨unlocked, readable, selected⟩ := hs
      have enabled : receiptAllowed (f facts "policy") = true := by
        cases he : receiptAllowed (f facts "policy") <;> simp_all
      have picked : findReceipt facts p (f source "label") (f effect "destination") = some id := by
        simpa [readable, enabled] using selected
      obtain ⟨r, member, valid, covers, rid⟩ := receipt_sound picked
      subst id
      exact .receipt r (unsealed_sound unlocked) readable enabled member valid covers
  · contradiction
  · contradiction
  · contradiction

theorem sources_sound {entries : List Term}
    (h : items.mapM (fun source => admitSource source effect activation p facts) = .ok entries) :
    EvidenceSources effect activation p facts items entries := by
  induction items generalizing entries with
  | nil => simp at h; subst entries; exact .nil
  | cons item rest ih =>
    cases first : admitSource item effect activation p facts with
    | error why => simp [List.mapM_cons, first] at h
    | ok entry =>
      cases tail : rest.mapM (fun source => admitSource source effect activation p facts) with
      | error why => simp [List.mapM_cons, first, tail] at h
      | ok entries' =>
        simp [List.mapM_cons, first, tail] at h
        subst entries
        exact .cons (source_sound first) (ih tail)

theorem selected_refs_sound {refs selected : List Term}
    (h : refs.mapM (resolveSource items) = .ok selected) :
    SelectedRefs items refs selected := by
  induction refs generalizing selected with
  | nil => simp at h; subst selected; exact .nil
  | cons ref refs ih =>
    cases found : items.find? (fun item => f item "ref" == ref) with
    | none => simp [List.mapM_cons, resolveSource, found] at h
    | some item =>
      cases tail : refs.mapM (resolveSource items) with
      | error why => simp [List.mapM_cons, tail, resolveSource, found] at h
      | ok rest =>
        simp [List.mapM_cons, tail, resolveSource, found] at h
        subst selected
        have matched := List.find?_some found
        exact .cons (List.mem_of_find?_eq_some found) matched (ih tail)

theorem resolve_sources_sound (h : resolveSources effect request items = .ok sources) :
    Resolves effect request items sources := by
  unfold resolveSources at h
  split at h
  · simp only [Except.ok.injEq] at h
    exact Or.inl ⟨by assumption, h.symm⟩
  · rename_i explicit
    cases selected : collectSources (resolveSource items) (values (f effect "sources")) with
    | error why => simp [selected] at h
    | ok xs =>
      simp [selected] at h
      exact Or.inr ⟨by simpa using explicit, xs, selected_refs_sound ((collectSources_ok _ _ _).mp selected), h.symm⟩

theorem decideChecked_sound
    (h : decideChecked effect activation rawItems facts = .ok evidence) :
    Authorized effect activation rawItems facts evidence := by
  unfold decideChecked at h
  cases hv : validate effect activation rawItems facts with
  | error why => simp [hv] at h
  | ok result =>
    cases result
    cases hu : checkUniqueRefs (values rawItems) with
    | error why => simp [hv, hu] at h
    | ok result =>
      cases result
      cases hr : resolveRequest effect activation (values rawItems) with
      | error why => simp [hv, hu, hr] at h
      | ok request =>
        cases resolved : resolveSources effect request (values rawItems) with
        | error why => simp [hv, hu, hr, resolved] at h
        | ok sources =>
          cases hp : checkPublic effect sources facts with
          | error why => simp [hv, hu, hr, resolved, hp] at h
          | ok result =>
            cases result
            cases hw : checkWriter effect activation (f request "principal") facts with
            | error why => simp [hv, hu, hr, resolved, hp, hw] at h
            | ok result =>
              cases result
              cases hs : collectSources
                  (fun source => admitSource source effect activation (f request "principal") facts) sources with
              | error why => simp [hv, hu, hr, resolved, hp, hw, hs] at h
              | ok entries =>
                simp [hv, hu, hr, resolved, hp, hw, hs] at h
                obtain ⟨present, authorized⟩ := resolve_request_sound hr
                refine ⟨validate_sound hv, unique_refs_sound hu, request, present, authorized,
                  writer_sound hw, sources, resolve_sources_sound resolved, public_sound hp, entries,
                  consultedRevisions effect facts sources, rfl,
                  sources_sound ((collectSources_ok _ _ _).mp hs), ?_⟩
                subst evidence
                rfl

theorem decide_allow_iff :
    decide effect activation items facts = .tuple [a "allow", evidence] ↔
      decideChecked effect activation items facts = .ok evidence := by
  cases checked : decideChecked effect activation items facts with
  | ok result => simp [decide, checked]
  | error why => simp [decide, checked, a]

theorem decide_allow_sound
    (h : decide effect activation items facts = .tuple [a "allow", evidence]) :
    Authorized effect activation items facts evidence :=
  decideChecked_sound (decide_allow_iff.mp h)

end VerifiedKernel.IFC.FullRefinement
