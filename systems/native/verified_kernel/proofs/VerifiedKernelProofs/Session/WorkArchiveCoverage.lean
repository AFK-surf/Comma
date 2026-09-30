import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkArchiveTrace

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation WorkConservation.ValueSemantics
set_option Elab.async false
variable {owner : Term × Term}

def StoredMessage (objects : Objects) (agent session record : Term) : Prop :=
  ∃ first records actual, objects (key agent session first) records ∧
    actual ∈ records ∧ Equivalent record actual

def CatalogMessage (objects : Objects) (agent session : Term) (catalog : List Term) (record : Term) : Prop :=
  ∃ records count actual, entry records count ∈ catalog ∧
    objects (key agent session ((records.head?.getD nil).get (a "seq"))) records ∧
    actual ∈ records ∧ Equivalent record actual

def WindowProgress (objects : Objects) (original : List Term) (owner : Term × Term) (cursor : Cursor) : Prop :=
  (cursor.agent, cursor.session) = owner ∧ EntriesBacked objects cursor ∧
    ∃ removed, original = removed ++ cursor.remaining ∧
    (∀ record ∈ removed, record.get (a "kind") = b "message" →
      CatalogMessage objects cursor.agent cursor.session (cursor.catalog ++ cursor.entries) record) ∧
    (cursor.entries ≠ [] → Equivalent ((wrap (cursor.entries.head?.getD nil))[1]?.getD nil)
      ((removed.getLast?.getD nil).get (a "seq")))

def ProgressOutput (objects : Objects) (original : List Term) (owner : Term × Term) (output : Output) : Prop :=
  (∃ reason, output = failed reason) ∨
  (∃ cursor, WindowProgress objects original owner cursor ∧
    ((∃ request, output = (some cursor, request)) ∨ output = complete cursor))

theorem StoredMessage.mono {before after : Objects} {agent session record : Term}
    (extension : ObjectsExtend before after) (stored : StoredMessage before agent session record) :
    StoredMessage after agent session record := by
  obtain ⟨first, records, actual, fact, member, same⟩ := stored
  exact ⟨first, records, actual, extension _ _ fact, member, same⟩

theorem CatalogMessage.mono {before after : Objects} {agent session record : Term} {catalog : List Term}
    (extension : ObjectsExtend before after) (stored : CatalogMessage before agent session catalog record) :
    CatalogMessage after agent session catalog record := by
  obtain ⟨records, count, actual, listed, fact, member, same⟩ := stored
  exact ⟨records, count, actual, listed, extension _ _ fact, member, same⟩

theorem CatalogMessage.catalog_mono {objects : Objects} {agent session record : Term} {before after : List Term}
    (included : ∀ entry ∈ before, entry ∈ after) (stored : CatalogMessage objects agent session before record) :
    CatalogMessage objects agent session after record := by
  obtain ⟨records, count, actual, listed, fact, member, same⟩ := stored
  exact ⟨records, count, actual, included _ listed, fact, member, same⟩

theorem CatalogMessage.stored {objects : Objects} {agent session record : Term} {catalog : List Term}
    (stored : CatalogMessage objects agent session catalog record) : StoredMessage objects agent session record := by
  obtain ⟨records, count, actual, listed, fact, member, same⟩ := stored
  exact ⟨_, records, actual, fact, member, same⟩

theorem WindowProgress.mono {before after : Objects} {original : List Term} {cursor : Cursor}
    (extension : ObjectsExtend before after) (progress : WindowProgress before original owner cursor) :
    WindowProgress after original owner cursor := by
  obtain ⟨ownerEq, entries, removed, partition, stored, last⟩ := progress
  exact ⟨ownerEq, entries.mono extension, removed, partition,
    fun record member kind => (stored record member kind).mono extension, last⟩

theorem progress_failed (objects : Objects) (original : List Term) (reason : Term) :
    ProgressOutput objects original owner (failed reason) := Or.inl ⟨reason, rfl⟩

theorem progress_complete {objects : Objects} {original : List Term} {cursor : Cursor}
    (progress : WindowProgress objects original owner cursor) : ProgressOutput objects original owner (complete cursor) :=
  Or.inr ⟨cursor, progress, Or.inr rfl⟩

theorem progress_pending {objects : Objects} {original : List Term} {cursor : Cursor} (request : Term)
    (progress : WindowProgress objects original owner cursor) : ProgressOutput objects original owner (some cursor, request) :=
  Or.inr ⟨cursor, progress, Or.inl ⟨request, rfl⟩⟩

theorem progress_proceed {objects : Objects} {original : List Term} {cursor : Cursor}
    (progress : WindowProgress objects original owner cursor) : ProgressOutput objects original owner (proceed cursor) := by
  unfold proceed
  split
  · exact progress_complete progress
  · split
    · exact progress_complete progress
    · exact progress_pending _ progress

theorem progress_compare {objects : Objects} {original : List Term} {cursor : Cursor} {records : List Term}
    (progress : WindowProgress objects original owner cursor) : ProgressOutput objects original owner (compare cursor records) := by
  unfold compare
  split
  · exact progress_failed _ _ _
  · exact progress_pending _ progress

theorem progress_propose {objects : Objects} {original : List Term} {cursor : Cursor}
    (progress : WindowProgress objects original owner cursor) : ProgressOutput objects original owner (propose cursor) := by
  unfold propose
  split
  · exact progress_failed _ _ _
  · exact progress_complete progress
  · split
    · exact progress_failed _ _ _
    · exact progress_pending _ progress

theorem progress_advance {objects : Objects} {original records : List Term} {cursor : Cursor} {catalogEntry : Term}
    (progress : WindowProgress objects original owner cursor)
    (added : CatalogBacked objects cursor.agent cursor.session catalogEntry)
    (nonempty : cursor.remaining.take records.length ≠ [])
    (stored : ∀ record ∈ cursor.remaining.take records.length,
      record.get (a "kind") = b "message" →
        CatalogMessage objects cursor.agent cursor.session (cursor.catalog ++ catalogEntry :: cursor.entries) record)
    (last : Equivalent ((wrap catalogEntry)[1]?.getD nil)
      (((cursor.remaining.take records.length).getLast?.getD nil).get (a "seq"))) :
    ProgressOutput objects original owner (advance cursor records catalogEntry) := by
  apply progress_proceed
  obtain ⟨ownerEq, entries, removed, partition, previous, _⟩ := progress
  refine ⟨ownerEq, ?_, removed ++ cursor.remaining.take records.length, ?_, ?_, ?_⟩
  · intro value member
    rcases List.mem_append.mp member with original | pending
    · exact entries value (List.mem_append_left _ original)
    · rcases List.mem_cons.mp pending with same | old
      · exact same ▸ added
      · exact entries value (List.mem_append_right _ old)
  · simpa only [List.append_assoc, List.take_append_drop] using partition
  · intro record member kind
    rcases List.mem_append.mp member with old | fresh
    · apply (previous record old kind).catalog_mono
      intro value member
      rcases List.mem_append.mp member with catalog | entries
      · exact List.mem_append_left _ catalog
      · exact List.mem_append_right _ (List.mem_cons_of_mem _ entries)
    · exact stored record fresh kind
  · intro _
    simpa only [List.head?_cons, Option.getD_some, List.getLast?_append,
      List.getLast?_eq_some_getLast nonempty, Option.or] using last

theorem equivalent_last {left right : List Term}
    (same : Equivalent (list left) (list right)) :
    Equivalent (left.getLast?.getD nil) (right.getLast?.getD nil) := by
  have length : left.length = right.length := Shape.list.inj same.shape
  have related := same.access (.index (left.length - 1))
  change Equivalent (left[left.length - 1]?.getD nil) (right[left.length - 1]?.getD nil) at related
  simpa only [List.getLast?_eq_getElem?, length] using related

theorem canonical_last_sequence (records : List Term) :
    (((records.map ArchiveMatch.canonical).getLast?).getD nil).get (a "seq") =
      (records.getLast?.getD nil).get (a "seq") := by
  rw [List.getLast?_map]
  cases found : records.getLast? with
  | none => rfl
  | some record => exact canonical_sequence record

theorem compared_progress {objects : Objects} {original records : List Term} {cursor : Cursor} {catalogEntry : Term}
    (progress : WindowProgress objects original owner cursor)
    (valid : validate records none = true)
    (stored : objects (address cursor) records)
    (same : Equivalent (list (records.map ArchiveMatch.canonical))
      (list ((cursor.remaining.take records.length).map ArchiveMatch.canonical)))
    (measured : measuredEntry records = .ok catalogEntry) :
    ProgressOutput objects original owner (advance cursor records catalogEntry) := by
  have nonempty : cursor.remaining.take records.length ≠ [] := by
    obtain ⟨first, rest, seq, recordsEq, _⟩ := validate_first valid
    intro empty
    have sizes := same.shape
    rw [empty] at sizes
    simp [recordsEq, shape, list] at sizes
  obtain ⟨count, entryEq⟩ := measured_entry_fields measured
  apply progress_advance progress (matched_catalog_fact stored valid same measured) nonempty
  · intro record member kind
    obtain ⟨actual, present, equivalent⟩ := archive_match_message_fact same member kind
    have located := stored
    unfold address at located
    rw [matched_first valid same] at located
    exact ⟨records, count, actual, by rw [entryEq]; simp, located, present, equivalent⟩
  · rw [entryEq]
    have related := (equivalent_last same).get (a "seq")
    rw [canonical_last_sequence, canonical_last_sequence] at related
    exact related

theorem created_progress {objects : Objects} {original records : List Term} {cursor : Cursor} {count : Nat}
    (progress : WindowProgress objects original owner cursor)
    (nonempty : records ≠ [])
    (partition : cursor.remaining = records ++ cursor.remaining.drop records.length)
    (stored : objects (address cursor) records) :
    ProgressOutput objects original owner (advance cursor records (entry records count)) := by
  have prefixEq : cursor.remaining.take records.length = records := by
    conv => lhs; rw [partition]
    simp
  have located := stored
  unfold address at located
  rw [prefix_first nonempty partition] at located
  apply progress_advance progress ⟨records, count, located, rfl⟩ (by rwa [prefixEq])
  · intro record member _
    rw [prefixEq] at member
    have located := stored
    unfold address at located
    rw [prefix_first nonempty partition] at located
    exact ⟨records, count, record, by simp, located, member, Equivalent.refl _⟩
  · rw [prefixEq]
    exact Equivalent.refl _

theorem resume_progress {before after : Objects} {original : List Term} {cursor : Cursor} {request result : Term}
    (backed : CursorBacked before cursor request)
    (progress : WindowProgress before original owner cursor)
    (primitive : PrimitiveStep before after request result) :
    ProgressOutput after original owner (resume cursor result) := by
  obtain ⟨extension, read, create, existing, codec⟩ := primitive
  have current := progress.mono extension
  have pending := backed.2
  unfold Pending at pending
  unfold resume
  split
  · split
    · exact progress_compare current
    · exact progress_failed _ _ _
    · exact progress_propose current
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
  · rename_i records catalogEntry phase
    rw [phase] at pending
    obtain ⟨count, bytes, nonempty, partition, entryEq, encoded, requestEq⟩ := pending
    have created (confirmed : result = a "created" ∨ result = a "landed") :
        ProgressOutput after original owner (advance cursor records catalogEntry) := by
      rw [entryEq]
      exact created_progress current nonempty partition
        (create cursor.agent cursor.session _ bytes records requestEq encoded confirmed)
    split
    · exact created (Or.inl rfl)
    · exact created (Or.inr rfl)
    · exact progress_compare current
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
  · rename_i records phase
    rw [phase] at pending
    obtain ⟨valid, stored, requestEq⟩ := pending
    rw [requestEq] at codec
    dsimp only
    split
    · rename_i checked
      have same := comparison_values codec checked
      split
      · rename_i catalogEntry measured
        exact compared_progress current valid (extension _ _ stored) same measured
      · exact progress_failed _ _ _
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _
    · exact progress_failed _ _ _

theorem ProgressOutput.pending {objects : Objects} {original : List Term} {cursor : Cursor} {request : Term}
    (progress : ProgressOutput objects original owner (some cursor, request)) : WindowProgress objects original owner cursor := by
  rcases progress with ⟨reason, impossible⟩ | ⟨next, current, pending | completed⟩
  · cases congrArg Prod.fst impossible
  · obtain ⟨_, same⟩ := pending
    cases congrArg Prod.fst same
    exact current
  · have impossible := congrArg Prod.fst completed
    rw [complete_no_cursor] at impossible
    cases impossible

theorem execution_progress {initial final : Output} {before after : Objects} {original : List Term}
    (execution : Execution initial before final after)
    (backed : OutputBacked before initial) (progress : ProgressOutput before original owner initial) :
    ProgressOutput after original owner final := by
  induction execution with
  | done => exact progress
  | step primitive tail ih =>
    exact ih (resume_backed (backed.2 _ rfl) primitive)
      (resume_progress (backed.2 _ rfl) progress.pending primitive)

theorem start_progress {objects : Objects} {state : Term} {records : List Term} {ceiling line : Int}
    (initial : StateCatalogBacked objects state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) : ProgressOutput objects records (state.get (a "agent_id"), state.get (a "session_id")) (start state (i line)) := by
  unfold start
  simp only [i, show ¬line ≤ 0 by omega, ↓reduceIte, window]
  apply progress_proceed
  exact ⟨rfl, by simpa only [EntriesBacked, StateCatalogBacked, List.append_nil] using initial,
    [], rfl, by simp, by simp⟩

theorem publication_prefix_preserved {state event : Term} {records : List Term} {ceiling line : Int}
    {before after : Objects} {final : Output}
    (initial : StateCatalogBacked before state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) :
    ∃ cursor, final = complete cursor ∧ WindowProgress after records (state.get (a "agent_id"), state.get (a "session_id")) cursor := by
  have progress := execution_progress execution (start_backed initial) (start_progress initial window positive)
  rcases progress with ⟨reason, failedEq⟩ | ⟨cursor, current, pending | completed⟩
  · rw [failedEq] at emitted
    simp [failed, a] at emitted
  · obtain ⟨request, outputEq⟩ := pending
    have backed := execution_backed execution (start_backed initial)
    rw [outputEq] at backed emitted
    exact (pending_not_advance (backed.2 _ rfl).2 emitted).elim
  · exact ⟨cursor, completed, current⟩

theorem publication_scoped_catalog {state event : Term} {records : List Term} {ceiling line : Int}
    {before after : Objects} {final : Output}
    (initial : StateCatalogBacked before state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) :
    ∀ catalogEntry ∈ wrap (event.get (b "segments")),
      CatalogBacked after (state.get (a "agent_id")) (state.get (a "session_id")) catalogEntry := by
  obtain ⟨cursor, completed, ownerEq, entries, _⟩ :=
    publication_prefix_preserved initial window positive execution emitted
  rw [completed] at emitted
  obtain ⟨last, earlier, entriesEq, eventEq⟩ :=
    complete_advance (Prod.ext (complete_no_cursor cursor) emitted)
  have owner := Prod.mk.inj ownerEq
  intro catalogEntry member
  rw [eventEq] at member
  change catalogEntry ∈ cursor.catalog ++ cursor.entries.reverse at member
  rw [← owner.1, ← owner.2]
  apply entries catalogEntry
  simpa only [List.mem_append, List.mem_reverse] using member

/-- The emitted watermark is the last removed record; each removed message has a physical object witness. -/
theorem publication_removed_records {state event : Term} {records : List Term} {ceiling line : Int}
    {before after : Objects} {final : Output}
    (initial : StateCatalogBacked before state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) :
    ∃ (cursor : Cursor) (removed : List Term) (through : Term),
      (cursor.agent, cursor.session) = (state.get (a "agent_id"), state.get (a "session_id")) ∧
      records = removed ++ cursor.remaining ∧
      event = .map [(b "type", b "archive_advance"), (b "session_id", cursor.session),
        (b "archived_through", through), (b "segments", list (cursor.catalog ++ cursor.entries.reverse))] ∧
      Equivalent through ((removed.getLast?.getD nil).get (a "seq")) ∧
      ∀ record ∈ removed, record.get (a "kind") = b "message" →
        CatalogMessage after cursor.agent cursor.session (cursor.catalog ++ cursor.entries) record := by
  obtain ⟨cursor, completed, ownerEq, _, removed, partition, stored, bound⟩ :=
    publication_prefix_preserved initial window positive execution emitted
  rw [completed] at emitted
  obtain ⟨last, earlier, entriesEq, eventEq⟩ :=
    complete_advance (Prod.ext (complete_no_cursor cursor) emitted)
  refine ⟨cursor, removed, (wrap last)[1]?.getD nil, ownerEq, partition, eventEq, ?_, stored⟩
  simpa only [entriesEq, List.head?_cons, Option.getD_some] using
    bound (by rw [entriesEq]; simp)

theorem StoredMessage.input_fact {objects : Objects} {agent session item record projected : Term}
    (stored : StoredMessage objects agent session projected)
    (projection : ArchiveProjection.MessageRecord record projected)
    (recorded : Recorded item record) :
    ∃ first records actual, objects (key agent session first) records ∧ actual ∈ records ∧
      Equivalent (queueWorkProjection item) ((actual.get (a "data")).get (b "accepted_input")) := by
  obtain ⟨first, records, actual, fact, member, same⟩ := stored
  exact ⟨first, records, actual, fact, member,
    (projection.input_fact recorded).trans ((same.get (a "data")).get (b "accepted_input"))⟩

theorem CatalogMessage.input_fact {objects : Objects} {agent session item record projected : Term} {catalog : List Term}
    (stored : CatalogMessage objects agent session catalog projected)
    (projection : ArchiveProjection.MessageRecord record projected)
    (recorded : Recorded item record) :
    ∃ first records actual, objects (key agent session first) records ∧ actual ∈ records ∧
      Equivalent (queueWorkProjection item) ((actual.get (a "data")).get (b "accepted_input")) :=
  stored.stored.input_fact projection recorded

end VerifiedKernel.Session.ArchivePublication
