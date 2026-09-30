import VerifiedKernelProofs.Session.WorkArchiveCoverage
import VerifiedKernelProofs.Session.WorkArchiveExecution

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

/-- The exact fold step used by the production archive-window query. -/
def windowCheck (result record : Term) : KernelM Term := do
  match result with
  | .tuple [.atom "error", _] => pure result
  | expected =>
    let seq := record.get (a "seq")
    if seq != expected then
      return .tuple [a "error", .tuple [a "window_seq_gap", expected, seq]]
    add expected (i 1)

inductive Numbered : Int → List Term → Prop where
  | nil (first : Int) : Numbered first []
  | cons {first : Int} {record : Term} {rest : List Term}
      (stamp : record.get (a "seq") = i first) (tail : Numbered (first + 1) rest) :
      Numbered first (record :: rest)

theorem window_error_absorbs (records : List Term) (reason : Term) :
    records.foldlM windowCheck (.tuple [a "error", reason]) = pure (.tuple [a "error", reason]) := by
  induction records with
  | nil => rfl
  | cons record rest ih =>
    simp only [List.foldlM_cons, windowCheck, a]
    exact ih

theorem beq_integer_value {value : Term} {n : Int} (same : (value == i n) = true) : value = i n := by
  cases value with
  | integer v =>
    have equal : v = n := eq_of_beq same
    cases equal
    rfl
  | _ => cases same

theorem window_fold_numbered {records : List Term} {first : Int} {checked : Term} {j r : List Term}
    (h : records.foldlM windowCheck (i first) j = .ok (checked, r))
    (success : ∀ reason, checked ≠ .tuple [a "error", reason]) : Numbered first records := by
  induction records generalizing first j with
  | nil => exact .nil first
  | cons record rest ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨next, middle, step, h⟩ := bind_ok h
    unfold windowCheck at step
    dsimp only [i] at step
    split at step
    · have nextEq := pure_ok step
      subst next
      rw [window_error_absorbs] at h
      exact (success _ (pure_ok h)).elim
    · rename_i equal
      have stamp : record.get (a "seq") = i first := beq_integer_value (by simpa [bne] using equal)
      rw [add_integer] at step
      have nextEq := (Prod.mk.inj (Except.ok.inj step)).1
      subst next
      exact .cons stamp (ih h)

theorem archiveWindow_numbered {state ceiling : Term} {records : List Term} {base : Int} {j r : List Term}
    (numeric : (state.get (a "archived_through")).default (i 0) = i base)
    (h : StorageQuery.archiveWindow state j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    Numbered (base + 1) records := by
  unfold StorageQuery.archiveWindow at h
  obtain ⟨projected, _, _, h⟩ := bind_ok h
  obtain ⟨stored, _, storedRead, h⟩ := bind_ok h
  have storedEq := field_value storedRead
  rw [storedEq, numeric] at h
  obtain ⟨first, _, added, h⟩ := bind_ok h
  rw [add_integer] at added
  have firstEq := (Prod.mk.inj (Except.ok.inj added)).1
  subst first
  obtain ⟨values, _, valuesRead, h⟩ := bind_ok h
  obtain ⟨checked, _, checkedRead, h⟩ := bind_ok h
  split at h
  · have impossible := pure_ok h
    simp [a, Term.tuple.injEq] at impossible
  · rename_i success
    obtain ⟨_, _, _, h⟩ := bind_ok h
    have equal := pure_ok h
    simp only [Term.tuple.injEq, List.cons.injEq, true_and, and_true] at equal
    have projectedEq := equal.1
    subst projected
    have valuesEq : values = records := by
      exact (Prod.mk.inj (Except.ok.inj valuesRead)).1.symm
    subst values
    apply window_fold_numbered checkedRead
    intro reason impossible
    exact success reason impossible

theorem Numbered.lower {records : List Term} {first : Int} (numbered : Numbered first records) :
    ∀ record ∈ records, first ≤ integerValue (record.get (a "seq")) := by
  induction numbered with
  | nil => simp
  | @cons first head rest stamp tail ih =>
    intro record member
    rcases List.mem_cons.mp member with rfl | later
    · simp [stamp, integerValue, i]
    · have bound := ih record later
      omega

theorem Numbered.strict {records : List Term} {first : Int} (numbered : Numbered first records) :
    records.Pairwise (fun left right => integerValue (left.get (a "seq")) < integerValue (right.get (a "seq"))) := by
  induction numbered with
  | nil => exact .nil
  | @cons first record rest stamp tail ih =>
    apply List.pairwise_cons.mpr
    refine ⟨?_, ih⟩
    intro next member
    have bound := tail.lower next member
    rw [stamp]
    change first < integerValue (next.get (a "seq"))
    omega

theorem prefix_covers_watermark {records removed remaining : List Term} {first : Int} {through record : Term}
    (numbered : Numbered first records) (positive : first > 0)
    (partition : records = removed ++ remaining)
    (watermark : ValueSemantics.Equivalent through ((removed.getLast?.getD nil).get (a "seq")))
    (member : record ∈ records)
    (bounded : integerValue (record.get (a "seq")) ≤ integerValue through) : record ∈ removed := by
  have value := watermark.integerValue
  by_cases empty : removed = []
  · rw [empty] at value
    have zero : integerValue through = 0 := value
    have lower := numbered.lower record member
    omega
  · rw [partition] at member
    rcases List.mem_append.mp member with included | later
    · exact included
    · have sorted := numbered.strict
      rw [partition] at sorted
      have cross := (List.pairwise_append.mp sorted).2.2
      have lastMember : removed.getLast?.getD nil ∈ removed := by
        simpa only [List.getLast?_eq_some_getLast empty, Option.getD_some] using List.getLast_mem empty
      have ordered := cross _ lastMember _ later
      omega

theorem message_projection_sequence {record projected : Term}
    (projection : ArchiveProjection.MessageRecord record projected) :
    projected.get (a "seq") = record.get (a "seq") := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, equal⟩ := projection
  rw [equal]
  rfl

/-- Compose actual publication with actual removal on the captured Session state. -/
theorem published_archive_removed_projections {state event next : Term} {records live : List Term}
    {base ceiling line : Int} {before after : Objects} {final : Output} {j r : List Term}
    (sorted : SeqSorted state)
    (numeric : (state.get (a "archived_through")).default (i 0) = i base) (nonnegative : base ≥ 0)
    (initial : StateCatalogBacked before state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (read : state.get (a "messages") = list live)
    (reduced : archiveAdvance state event j = .ok (next, r)) :
    ∃ (dropped kept : List Term),
      live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      ∀ record ∈ dropped, ∃ projected, ArchiveProjection.MessageRecord record projected ∧
        CatalogMessage after (state.get (a "agent_id")) (state.get (a "session_id"))
          (wrap (event.get (b "segments"))) projected := by
  obtain ⟨cursor, removed, through, ownerEq, partition, eventEq, watermark, stored⟩ :=
    publication_removed_records initial window positive execution emitted
  have owner := Prod.mk.inj ownerEq
  rw [owner.1, owner.2] at stored
  have numbered := archiveWindow_numbered numeric window
  obtain ⟨dropped, kept, splitLive, nextRead, bounded⟩ :=
    archiveAdvance_executed_prefix sorted read reduced
  refine ⟨dropped, kept, splitLive, nextRead, ?_⟩
  intro record member
  have liveMember : record ∈ live := by
    rw [splitLive]
    exact List.mem_append_left _ member
  obtain ⟨projected, projectedMember, projection⟩ :=
    ArchiveProjection.archiveWindow_messages sorted read liveMember window
  have throughRead : event.get (b "archived_through") = through := by rw [eventEq]; rfl
  have bound := bounded record member
  rw [throughRead] at bound
  have removedMember := prefix_covers_watermark numbered (by omega) partition watermark projectedMember
    (by rwa [message_projection_sequence projection])
  refine ⟨projected, projection, (stored projected removedMember projection.kind).catalog_mono ?_⟩
  intro value member
  have catalogRead : wrap (event.get (b "segments")) = cursor.catalog ++ cursor.entries.reverse := by
    rw [eventEq]
    rfl
  rw [catalogRead]
  simpa only [List.mem_append, List.mem_reverse] using member

end VerifiedKernel.Session.ArchivePublication
