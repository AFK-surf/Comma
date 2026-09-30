import VerifiedKernelProofs.Session.WorkArchiveObjects

namespace VerifiedKernel.Session.ArchivePublication
open Data
set_option Elab.async false

def ObjectsExtend (before after : Objects) : Prop :=
  ∀ address records, before address records → after address records

def PrimitiveStep (before after : Objects) (request result : Term) : Prop :=
  ObjectsExtend before after ∧ ReadMeaning request result after ∧
    CreateMeaning request result after ∧ ExistingMeaning request result after ∧ CodecMeaning request result

def EntriesBacked (objects : Objects) (cursor : Cursor) : Prop :=
  ∀ catalogEntry ∈ cursor.catalog ++ cursor.entries,
    CatalogBacked objects cursor.agent cursor.session catalogEntry

def Pending (objects : Objects) (cursor : Cursor) (request : Term) : Prop :=
  match cursor.phase with
  | .read => request = objectRequest cursor "read_segment"
  | .create records catalogEntry =>
    ∃ count bytes, records ≠ [] ∧
      cursor.remaining = records ++ cursor.remaining.drop records.length ∧
      catalogEntry = entry records count ∧ ETF.encode (list records) = .ok bytes ∧
      request = objectRequest cursor "create_segment" [.binary bytes]
  | .compare records =>
    validate records none = true ∧ objects (address cursor) records ∧
      request = ArchiveMatch.request records (cursor.remaining.take records.length)

def CursorBacked (objects : Objects) (cursor : Cursor) (request : Term) : Prop :=
  EntriesBacked objects cursor ∧ Pending objects cursor request

def EventBacked (objects : Objects) (event : Term) : Prop :=
  ∃ agent session through catalog,
    event = .map [(b "type", b "archive_advance"), (b "session_id", session),
      (b "archived_through", through), (b "segments", list catalog)] ∧
      ∀ catalogEntry ∈ catalog, CatalogBacked objects agent session catalogEntry

def OutputBacked (objects : Objects) (output : Output) : Prop :=
  (∀ event, output.2 = .tuple [a "advance", event] → EventBacked objects event) ∧
    (∀ cursor, output.1 = some cursor → CursorBacked objects cursor output.2)

theorem CatalogBacked.mono {before after : Objects} {agent session catalogEntry : Term}
    (extension : ObjectsExtend before after) (backed : CatalogBacked before agent session catalogEntry) :
    CatalogBacked after agent session catalogEntry := by
  obtain ⟨records, count, stored, entryEq⟩ := backed
  exact ⟨records, count, extension _ _ stored, entryEq⟩

theorem EntriesBacked.mono {before after : Objects} {cursor : Cursor}
    (extension : ObjectsExtend before after) (backed : EntriesBacked before cursor) : EntriesBacked after cursor :=
  fun entry member => (backed entry member).mono extension

theorem failed_backed (objects : Objects) (reason : Term) : OutputBacked objects (failed reason) := by
  constructor
  · intro event emitted
    simp [failed, a] at emitted
  · intro cursor found
    cases found

theorem complete_backed {objects : Objects} {cursor : Cursor}
    (backed : EntriesBacked objects cursor) : OutputBacked objects (complete cursor) := by
  constructor
  · intro event emitted
    obtain ⟨last, earlier, _, eventEq⟩ := complete_advance (Prod.ext (complete_no_cursor cursor) emitted)
    refine ⟨cursor.agent, cursor.session, (wrap last)[1]?.getD nil,
      cursor.catalog ++ cursor.entries.reverse, eventEq, ?_⟩
    intro catalogEntry member
    apply backed catalogEntry
    simpa only [List.mem_append, List.mem_reverse] using member
  · intro next found
    rw [complete_no_cursor] at found
    cases found

theorem pending_not_advance {objects : Objects} {cursor : Cursor} {request event : Term}
    (pending : Pending objects cursor request) (emitted : request = .tuple [a "advance", event]) : False := by
  unfold Pending at pending
  split at pending
  · rw [pending] at emitted
    simp [objectRequest, a] at emitted
  · obtain ⟨_, _, _, _, _, _, requestEq⟩ := pending
    rw [requestEq] at emitted
    simp [objectRequest, a] at emitted
  · rw [pending.2.2] at emitted
    simp [ArchiveMatch.request, a] at emitted

theorem pending_backed {objects : Objects} {cursor : Cursor} {request : Term}
    (backed : CursorBacked objects cursor request) : OutputBacked objects (some cursor, request) := by
  constructor
  · intro event emitted
    exact (pending_not_advance backed.2 emitted).elim
  · intro next found
    cases found
    exact backed

theorem proceed_backed {objects : Objects} {cursor : Cursor}
    (backed : EntriesBacked objects cursor) : OutputBacked objects (proceed cursor) := by
  unfold proceed
  split
  · exact complete_backed backed
  · split
    · exact complete_backed backed
    · exact pending_backed ⟨backed, rfl⟩

theorem compare_backed {objects : Objects} {cursor : Cursor} {records : List Term}
    (backed : EntriesBacked objects cursor) (stored : objects (address cursor) records) :
    OutputBacked objects (compare cursor records) := by
  unfold compare
  split
  · exact failed_backed _ _
  · rename_i valid
    exact pending_backed ⟨backed, by exact ⟨by simpa using valid, stored, rfl⟩⟩

theorem propose_backed {objects : Objects} {cursor : Cursor}
    (backed : EntriesBacked objects cursor) : OutputBacked objects (propose cursor) := by
  unfold propose
  cases selected : cut cursor.ceiling cursor.line cursor.remaining 0 with
  | error reason => exact failed_backed _ _
  | ok chosen =>
    obtain ⟨records, count⟩ := chosen
    cases records with
    | nil => exact complete_backed backed
    | cons record records =>
      dsimp only
      cases encoded : ETF.encode (list (record :: records)) with
      | error reason => exact failed_backed _ _
      | ok bytes =>
        apply pending_backed
        exact ⟨backed, count, bytes, by simp, cut_removal_exact selected, rfl, encoded, rfl⟩

theorem advance_backed {objects : Objects} {cursor : Cursor} {records : List Term} {catalogEntry : Term}
    (backed : EntriesBacked objects cursor)
    (added : CatalogBacked objects cursor.agent cursor.session catalogEntry) :
    OutputBacked objects (advance cursor records catalogEntry) := by
  apply proceed_backed
  intro value member
  rcases List.mem_append.mp member with original | pending
  · exact backed value (List.mem_append_left _ original)
  · rcases List.mem_cons.mp pending with same | old
    · exact same ▸ added
    · exact backed value (List.mem_append_right _ old)

theorem resume_backed {before after : Objects} {cursor : Cursor} {request result : Term}
    (backed : CursorBacked before cursor request)
    (primitive : PrimitiveStep before after request result) :
    OutputBacked after (resume cursor result) := by
  obtain ⟨extension, read, create, existing, codec⟩ := primitive
  have entries := backed.1.mono extension
  have pending := backed.2
  unfold Pending at pending
  unfold resume
  split
  · rename_i phase
    rw [phase] at pending
    split
    · apply compare_backed entries
      exact read _ _ _ _ pending rfl
    · exact failed_backed _ _
    · exact propose_backed entries
    · exact failed_backed _ _
    · exact failed_backed _ _
    · exact failed_backed _ _
  · rename_i records catalogEntry phase
    rw [phase] at pending
    obtain ⟨count, bytes, nonempty, partition, entryEq, encoded, requestEq⟩ := pending
    have created (confirmed : result = a "created" ∨ result = a "landed") :
        CatalogBacked after cursor.agent cursor.session catalogEntry := by
      have stored := create cursor.agent cursor.session _ bytes records requestEq encoded confirmed
      rw [prefix_first nonempty partition] at stored
      exact ⟨records, count, stored, entryEq⟩
    split
    · exact advance_backed entries (created (Or.inl rfl))
    · exact advance_backed entries (created (Or.inr rfl))
    · apply compare_backed entries
      exact existing _ _ _ bytes _ requestEq rfl
    · exact failed_backed _ _
    · exact failed_backed _ _
    · exact failed_backed _ _
    · exact failed_backed _ _
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
        exact advance_backed entries (matched_catalog_fact (extension _ _ stored) valid same measured)
      · exact failed_backed _ _
    · exact failed_backed _ _
    · exact failed_backed _ _
    · exact failed_backed _ _

/-- Finite executions of the production cursor. Only primitive observations are assumed. -/
inductive Execution : Output → Objects → Output → Objects → Prop where
  | done (output : Output) (objects : Objects) : Execution output objects output objects
  | step {cursor : Cursor} {request result : Term} {before middle after : Objects} {final : Output}
      (primitive : PrimitiveStep before middle request result)
      (tail : Execution (resume cursor result) middle final after) :
      Execution (some cursor, request) before final after

theorem execution_backed {initial final : Output} {before after : Objects}
    (execution : Execution initial before final after) (backed : OutputBacked before initial) :
    OutputBacked after final := by
  induction execution with
  | done => exact backed
  | step primitive tail ih =>
    exact ih (resume_backed (backed.2 _ rfl) primitive)

def StateCatalogBacked (objects : Objects) (state : Term) : Prop :=
  ∀ catalogEntry ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
    CatalogBacked objects (state.get (a "agent_id")) (state.get (a "session_id")) catalogEntry

theorem start_backed {objects : Objects} {state args : Term}
    (backed : StateCatalogBacked objects state) : OutputBacked objects (start state args) := by
  unfold start
  split
  · split
    · exact failed_backed _ _
    · split
      · apply proceed_backed
        simpa only [EntriesBacked, StateCatalogBacked, List.append_nil] using backed
      · exact failed_backed _ _
      · exact failed_backed _ _
      · exact failed_backed _ _
  · exact failed_backed _ _

/-- Every entry emitted after any finite publication execution has a stored object witness. -/
theorem publication_catalog_backed {state args event : Term} {final : Output} {before after : Objects}
    (initial : StateCatalogBacked before state)
    (execution : Execution (start state args) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) : EventBacked after event :=
  (execution_backed execution (start_backed initial)).1 event emitted

end VerifiedKernel.Session.ArchivePublication
