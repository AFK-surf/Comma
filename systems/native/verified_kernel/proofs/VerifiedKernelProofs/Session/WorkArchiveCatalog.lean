import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkArchiveWindow

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

/-- ETF values include their version byte. This is a codec-framing contract, not a catalog premise. -/
def CodecFraming : Prop := ∀ value bytes, ETF.encode value = .ok bytes → bytes.size > 0

theorem Numbered.length_stamp {records : List Term} {first : Int} (numbered : Numbered first records)
    (nonempty : records ≠ []) :
    (records.getLast?.getD Data.nil).get (a "seq") = i (first + records.length - 1) := by
  induction numbered with
  | nil => exact (nonempty rfl).elim
  | @cons first record rest stamp tail ih =>
    cases rest with
    | nil => simpa using stamp
    | cons head rest =>
      have last := ih (by simp)
      simpa [Int.add_assoc, Int.add_comm, Int.add_left_comm] using last

theorem Numbered.head_stamp {records : List Term} {first : Int} (numbered : Numbered first records)
    (nonempty : records ≠ []) : (records.head?.getD Data.nil).get (a "seq") = i first := by
  cases numbered with
  | nil => exact (nonempty rfl).elim
  | cons stamp tail => exact stamp

theorem Numbered.take {records : List Term} {first : Int} (numbered : Numbered first records) (n : Nat) :
    Numbered first (records.take n) := by
  induction numbered generalizing n with
  | nil => simpa using Numbered.nil _
  | cons stamp tail ih =>
    cases n with
    | zero => exact .nil _
    | succ n => exact .cons stamp (ih n)

theorem numbered_entry_valid {records : List Term} {first : Int} {bytes : Nat}
    (numbered : Numbered first records) (positive : first > 0)
    (nonempty : records ≠ []) (encoded : bytes > 0) : validSegment (entry records bytes) = true := by
  unfold entry
  rw [numbered.head_stamp nonempty, numbered.length_stamp nonempty]
  have count := List.length_filter_le (fun record : Term => record.get (a "kind") == b "message") records
  have length : records.length > 0 := List.length_pos_iff.mpr nonempty
  simp only [validSegment, list, i, Bool.and_eq_true, decide_eq_true_eq]
  omega

theorem cutLoop_count {records selected chosen : List Term} {ceiling : Int} {line bytes count : Nat}
    (framing : CodecFraming)
    (h : cutLoop ceiling line records selected bytes = .ok (chosen, count)) :
    count ≥ bytes ∧ (chosen.length > selected.length → count > bytes) := by
  induction records generalizing selected bytes with
  | nil =>
    cases h
    simp
  | cons record rest ih =>
    unfold cutLoop at h
    split at h
    · cases h
      simp
    · cases encoded : ETF.encode record with
      | error reason => simp [encoded, bind, Except.bind] at h
      | ok raw =>
        have positive := framing record raw encoded
        simp only [encoded, bind, Except.bind] at h
        split at h
        · cases h
          constructor <;> omega
        · have bound := (ih h).1
          constructor <;> omega

theorem cut_positive {records chosen : List Term} {ceiling : Int} {line count : Nat}
    (framing : CodecFraming) (nonempty : chosen ≠ [])
    (h : cut ceiling line records 0 = .ok (chosen, count)) : count > 0 :=
  (cutLoop_count framing h).2 (by simpa using List.length_pos_iff.mpr nonempty)

theorem validate_tail_numbered {records : List Term} {first : Int}
    (valid : validate records (some (first - 1)) = true) : Numbered first records := by
  induction records generalizing first with
  | nil => exact .nil _
  | cons record rest ih =>
    unfold validate at valid
    split at valid
    · rename_i seq stamp
      simp only [Option.isNone_some, Bool.false_or, Bool.and_eq_true, decide_eq_true_eq] at valid
      have same : first - 1 = seq - 1 := Option.some.inj (eq_of_beq valid.1.2)
      have seqEq : seq = first := by omega
      subst seq
      exact .cons stamp (ih (first := first + 1) (by simpa using valid.2))
    · cases valid

theorem validate_numbered {records : List Term} (valid : validate records none = true) :
    ∃ first, first > 0 ∧ Numbered first records ∧ records ≠ [] := by
  obtain ⟨record, rest, first, rfl, stamp⟩ := validate_first valid
  simp only [validate, stamp, i, Option.isNone_none, Bool.true_or, Bool.and_true,
    Bool.and_eq_true, decide_eq_true_eq] at valid
  exact ⟨first, valid.1.1.1, .cons stamp
    (validate_tail_numbered (first := first + 1) (by simpa using valid.2)), by simp⟩

def measuredCount (count : Nat) (record : Term) : Except String Nat := do
  let raw ← ETF.encode record
  return count + raw.size

theorem measured_count_positive {records : List Term} {initial count : Nat}
    (framing : CodecFraming)
    (h : records.foldlM measuredCount initial = .ok count) :
    count ≥ initial ∧ (records ≠ [] → count > initial) := by
  induction records generalizing initial with
  | nil => cases h; simp
  | cons record rest ih =>
    rw [List.foldlM_cons] at h
    cases encoded : ETF.encode record with
    | error reason => simp [measuredCount, encoded, bind, Except.bind] at h
    | ok raw =>
      simp only [measuredCount, encoded, bind, Except.bind, pure, Except.pure] at h
      have bound := (ih h).1
      have positive := framing record raw encoded
      constructor <;> omega

theorem measured_entry_valid {records : List Term} {catalogEntry : Term}
    (framing : CodecFraming) (valid : validate records none = true)
    (measured : measuredEntry records = .ok catalogEntry) : validSegment catalogEntry = true := by
  obtain ⟨first, positive, numbered, nonempty⟩ := validate_numbered valid
  unfold measuredEntry at measured
  change (records.foldlM measuredCount 0 >>= fun count => pure (entry records count)) = .ok catalogEntry at measured
  cases counted : records.foldlM measuredCount 0 with
  | error reason => simp [counted, bind, Except.bind] at measured
  | ok count =>
    simp only [counted, bind, Except.bind, pure, Except.pure, Except.ok.injEq] at measured
    rw [← measured]
    exact numbered_entry_valid numbered positive nonempty ((measured_count_positive framing counted).2 nonempty)

def PositiveWindow (records : List Term) : Prop := ∃ first, first > 0 ∧ Numbered first records

theorem Numbered.drop {records : List Term} {first : Int} (numbered : Numbered first records) (n : Nat) :
    ∃ offset : Nat, Numbered (first + offset) (records.drop n) := by
  induction numbered generalizing n with
  | nil => exact ⟨0, by simp; exact .nil _⟩
  | @cons first record rest stamp tail ih =>
    cases n with
    | zero => exact ⟨0, by simpa using Numbered.cons stamp tail⟩
    | succ n =>
      obtain ⟨offset, numbered⟩ := ih n
      exact ⟨offset + 1, by simpa [Int.add_assoc, Int.add_comm, Int.add_left_comm] using numbered⟩

theorem PositiveWindow.drop {records : List Term} (window : PositiveWindow records) (n : Nat) :
    PositiveWindow (records.drop n) := by
  obtain ⟨first, positive, numbered⟩ := window
  obtain ⟨offset, after⟩ := numbered.drop n
  exact ⟨first + offset, by omega, after⟩

def CursorValid (cursor : Cursor) : Prop :=
  PositiveWindow cursor.remaining ∧
    (∀ value ∈ cursor.catalog ++ cursor.entries, validSegment value = true) ∧
    (∀ records value, cursor.phase = .create records value → validSegment value = true)

def ValidOutput (output : Output) : Prop :=
  (∀ event, output.2 = .tuple [a "advance", event] →
    ∀ value ∈ wrap (event.get (b "segments")), validSegment value = true) ∧
  (∀ cursor, output.1 = some cursor → CursorValid cursor)

theorem valid_failed (reason : Term) : ValidOutput (failed reason) := by
  constructor
  · intro event emitted
    simp [failed, a] at emitted
  · intro cursor impossible
    cases impossible

theorem valid_complete {cursor : Cursor} (valid : CursorValid cursor) : ValidOutput (complete cursor) := by
  constructor
  · intro event emitted value member
    obtain ⟨_, _, _, eventEq⟩ := complete_advance (Prod.ext (complete_no_cursor cursor) emitted)
    have catalog : wrap (event.get (b "segments")) = cursor.catalog ++ cursor.entries.reverse := by
      rw [eventEq]
      rfl
    rw [catalog] at member
    apply valid.2.1 value
    simpa only [List.mem_append, List.mem_reverse] using member
  · intro next impossible
    rw [complete_no_cursor] at impossible
    cases impossible

theorem valid_pending {cursor : Cursor} {request : Term} (valid : CursorValid cursor)
    (requestSafe : ∀ event, request ≠ .tuple [a "advance", event]) : ValidOutput (some cursor, request) := by
  constructor
  · intro event emitted
    exact (requestSafe event emitted).elim
  · intro next found
    cases found
    exact valid

theorem valid_proceed {cursor : Cursor} (valid : CursorValid cursor) : ValidOutput (proceed cursor) := by
  unfold proceed
  split
  · exact valid_complete valid
  · split
    · exact valid_complete valid
    · exact valid_pending ⟨valid.1, valid.2.1, by intros; contradiction⟩
        (by intro event; simp [objectRequest, a])

theorem valid_compare {cursor : Cursor} {records : List Term}
    (valid : CursorValid cursor) : ValidOutput (compare cursor records) := by
  unfold compare
  split
  · exact valid_failed _
  · exact valid_pending ⟨valid.1, valid.2.1, by intros; contradiction⟩
      (by intro event; simp [ArchiveMatch.request, a])

theorem valid_advance {cursor : Cursor} {records : List Term} {catalogEntry : Term}
    (valid : CursorValid cursor) (added : validSegment catalogEntry = true) :
    ValidOutput (advance cursor records catalogEntry) := by
  apply valid_proceed
  refine ⟨valid.1.drop _, ?_, by intros; contradiction⟩
  intro value member
  rcases List.mem_append.mp member with old | recent
  · exact valid.2.1 value (List.mem_append_left _ old)
  · rcases List.mem_cons.mp recent with rfl | previous
    · exact added
    · exact valid.2.1 value (List.mem_append_right _ previous)

theorem valid_propose {cursor : Cursor} (framing : CodecFraming)
    (valid : CursorValid cursor) : ValidOutput (propose cursor) := by
  unfold propose
  cases selected : cut cursor.ceiling cursor.line cursor.remaining 0 with
  | error reason => exact valid_failed _
  | ok chosen =>
    obtain ⟨records, count⟩ := chosen
    cases records with
    | nil => exact valid_complete valid
    | cons record records =>
      dsimp only
      cases encoded : ETF.encode (list (record :: records)) with
      | error reason => exact valid_failed _
      | ok bytes =>
        have added : validSegment (entry (record :: records) count) = true := by
          obtain ⟨first, positive, numbered⟩ := valid.1
          have selectedNumbered := numbered.take (record :: records).length
          have partition := cut_removal_exact selected
          have prefixEq : cursor.remaining.take (record :: records).length = record :: records := by
            conv => lhs; rw [partition]
            simp
          rw [prefixEq] at selectedNumbered
          exact numbered_entry_valid selectedNumbered positive (by simp) (cut_positive framing (by simp) selected)
        dsimp only
        apply valid_pending
        · refine ⟨valid.1, valid.2.1, ?_⟩
          intro chosen value phase
          cases phase
          exact added
        · intro event
          simp [objectRequest, a]

theorem resume_valid {objects : Objects} {cursor : Cursor} {request result : Term}
    (framing : CodecFraming) (backed : CursorBacked objects cursor request)
    (valid : CursorValid cursor) : ValidOutput (resume cursor result) := by
  unfold resume
  split
  · split
    · exact valid_compare valid
    · exact valid_failed _
    · exact valid_propose framing valid
    · exact valid_failed _
    · exact valid_failed _
    · exact valid_failed _
  · rename_i records catalogEntry phase
    have added := valid.2.2 records catalogEntry phase
    split
    · exact valid_advance valid added
    · exact valid_advance valid added
    · exact valid_compare valid
    · exact valid_failed _
    · exact valid_failed _
    · exact valid_failed _
    · exact valid_failed _
  · rename_i records phase
    have prepared := backed.2
    unfold Pending at prepared
    rw [phase] at prepared
    dsimp only
    split
    · split
      · rename_i catalogEntry measured
        exact valid_advance valid (measured_entry_valid framing prepared.1 measured)
      · exact valid_failed _
    · exact valid_failed _
    · exact valid_failed _
    · exact valid_failed _

theorem execution_valid {initial final : Output} {before after : Objects}
    (framing : CodecFraming) (execution : Execution initial before final after)
    (backed : OutputBacked before initial) (valid : ValidOutput initial) : ValidOutput final := by
  induction execution with
  | done => exact valid
  | step primitive tail ih =>
    exact ih (resume_backed (backed.2 _ rfl) primitive)
      (resume_valid framing (backed.2 _ rfl) (valid.2 _ rfl))

theorem start_valid {state : Term} {records : List Term} {ceiling line : Int}
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (numbered : PositiveWindow records)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true) :
    ValidOutput (start state (i line)) := by
  unfold start
  simp only [i, show ¬line ≤ 0 by omega, ↓reduceIte, window]
  apply valid_proceed
  refine ⟨numbered, ?_, by intros; contradiction⟩
  simpa only [List.append_nil] using catalog

/-- The actual reducer's catalog filter cannot discard any entry emitted by a valid publication trace. -/
theorem publication_catalog_filter_exact {state event : Term} {records : List Term} {base ceiling line : Int}
    {before after : Objects} {final : Output}
    (framing : CodecFraming)
    (numeric : (state.get (a "archived_through")).default (i 0) = i base) (nonnegative : base ≥ 0)
    (initial : StateCatalogBacked before state)
    (catalog : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])), validSegment value = true)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0)
    (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event]) :
    (wrap (event.get (b "segments"))).filter validSegment = wrap (event.get (b "segments")) := by
  have numbered : PositiveWindow records := ⟨base + 1, by omega, archiveWindow_numbered numeric window⟩
  have valid := execution_valid framing execution (start_backed initial) (start_valid window positive numbered catalog)
  exact List.filter_eq_self.mpr (valid.1 event emitted)

end VerifiedKernel.Session.ArchivePublication
