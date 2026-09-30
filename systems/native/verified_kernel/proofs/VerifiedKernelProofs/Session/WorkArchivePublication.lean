import VerifiedKernelProofs.Session.Kernel
import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernel.Session.ArchivePublication
import VerifiedKernel.Dispatch

namespace VerifiedKernel.Session.ArchivePublication
open Data
set_option Elab.async false

theorem phase_roundtrip (phase : Phase) : Phase.unpack phase.pack = some phase := by
  cases phase <;> rfl

theorem cursor_roundtrip (cursor : Cursor) (positive : cursor.line > 0) :
    Cursor.unpack cursor.pack = some cursor := by
  have nonzero : ¬(cursor.line : Int) ≤ 0 := by omega
  simp only [Cursor.pack, Cursor.unpack, list, i,
    show (b "session_archive_cursor" != b "session_archive_cursor") = false from rfl,
    Bool.false_or, nonzero, decide_false, Bool.false_eq_true,
    ↓reduceIte, Int.toNat_natCast, phase_roundtrip]
  rfl

theorem resident_resume (cursor : Cursor) (positive : cursor.line > 0) (result : Term) :
    resident (some cursor.pack) (a "resume") result = packOutput (resume cursor result) := by
  simp only [resident, a, cursor_roundtrip cursor positive]

theorem archive_dispatch (current : Option Term) (operation args : Term) :
    SessionDomain.dispatch current
      (.tuple [i 1, a "session_archive", i 1, operation, args]) =
      let output := resident current operation args
      (output.1, .tuple [i 1, a "ok", output.2]) := rfl

/-- Every successful size cut contains an unchanged prefix of the captured window. -/
theorem cutLoop_partition {records selected chosen : List Term} {ceiling : Int}
    {line bytes total : Nat}
    (h : cutLoop ceiling line records selected bytes = .ok (chosen, total)) :
    ∃ rest, selected.reverse ++ records = chosen ++ rest := by
  induction records generalizing selected bytes with
  | nil =>
    cases h
    exact ⟨[], by simp⟩
  | cons record records ih =>
    unfold cutLoop at h
    split at h
    · cases h
      exact ⟨record :: records, rfl⟩
    · cases encoded : ETF.encode record with
      | error reason => simp [encoded, bind, Except.bind] at h
      | ok raw =>
        simp only [encoded, bind, Except.bind] at h
        split at h
        · cases h
          exact ⟨records, by simp [List.reverse_cons, List.append_assoc]⟩
        · obtain ⟨rest, partition⟩ := ih h
          exact ⟨rest, by simpa [List.reverse_cons, List.append_assoc] using partition⟩

theorem cut_partition {records chosen : List Term} {ceiling : Int} {line bytes total : Nat}
    (h : cut ceiling line records bytes = .ok (chosen, total)) :
    ∃ rest, records = chosen ++ rest := by
  simpa only [List.reverse_nil, List.nil_append] using cutLoop_partition h

theorem cut_removal_exact {records chosen : List Term} {ceiling : Int} {line bytes total : Nat}
    (h : cut ceiling line records bytes = .ok (chosen, total)) :
    records = chosen ++ records.drop chosen.length := by
  obtain ⟨rest, rfl⟩ := cut_partition h
  simp

theorem complete_no_cursor (cursor : Cursor) : (complete cursor).1 = none := by
  unfold complete
  split <;> rfl

theorem proceed_request {cursor next : Cursor} {request : Term}
    (h : proceed cursor = (some next, request)) :
    next = { cursor with phase := .read } ∧ request = objectRequest cursor "read_segment" := by
  unfold proceed at h
  split at h
  · have impossible := congrArg Prod.fst h
    rw [complete_no_cursor] at impossible
    cases impossible
  · split at h
    · have impossible := congrArg Prod.fst h
      rw [complete_no_cursor] at impossible
      cases impossible
    · cases h
      exact ⟨rfl, rfl⟩

theorem start_capture {state : Term} {line : Int} {cursor : Cursor} {request : Term}
    (h : start state (i line) = (some cursor, request)) :
    ∃ records ceiling,
      StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []) ∧
      line > 0 ∧
      cursor = ⟨state.get (a "agent_id"), state.get (a "session_id"), records, ceiling, line.toNat,
        wrap ((state.get (a "segment_catalog")).default (list [])), [], .read⟩ ∧
      request = objectRequest cursor "read_segment" := by
  unfold start at h
  dsimp only [i] at h
  split at h
  · have impossible := congrArg Prod.fst h
    cases impossible
  · rename_i positive
    split at h
    · rename_i records ceiling read
      obtain ⟨next, requested⟩ := proceed_request h
      cases next
      exact ⟨records, ceiling, read, by omega, rfl, requested⟩
    · have impossible := congrArg Prod.fst h
      cases impossible
    · have impossible := congrArg Prod.fst h
      cases impossible
    · have impossible := congrArg Prod.fst h
      cases impossible

/-- The actual create request encodes exactly the selected unchanged prefix. -/
theorem propose_request {cursor next : Cursor} {request : Term}
    (h : propose cursor = (some next, request)) :
    ∃ records count bytes,
      cut cursor.ceiling cursor.line cursor.remaining 0 = .ok (records, count) ∧
      records ≠ [] ∧ ETF.encode (list records) = .ok bytes ∧
      next = { cursor with phase := .create records (entry records count) } ∧
      request = objectRequest cursor "create_segment" [.binary bytes] ∧
      cursor.remaining = records ++ cursor.remaining.drop records.length := by
  unfold propose at h
  cases selected : cut cursor.ceiling cursor.line cursor.remaining 0 with
  | error reason =>
    simp only [selected] at h
    have impossible := congrArg Prod.fst h
    cases impossible
  | ok chosen =>
    obtain ⟨records, count⟩ := chosen
    cases records with
    | nil =>
      simp only [selected] at h
      have impossible := congrArg Prod.fst h
      rw [complete_no_cursor] at impossible
      cases impossible
    | cons record records =>
      simp only [selected] at h
      cases encoded : ETF.encode (list (record :: records)) with
      | error reason =>
        simp only [encoded] at h
        have impossible := congrArg Prod.fst h
        cases impossible
      | ok bytes =>
        simp only [encoded] at h
        cases h
        exact ⟨record :: records, count, bytes, rfl, by simp, encoded, rfl, rfl,
          cut_removal_exact selected⟩

/-- Final catalog construction uses only the captured catalog and accumulated publication entries. -/
theorem complete_advance {cursor : Cursor} {event : Term}
    (h : complete cursor = (none, .tuple [a "advance", event])) :
    ∃ last earlier, cursor.entries = last :: earlier ∧
      event = .map [(b "type", b "archive_advance"), (b "session_id", cursor.session),
        (b "archived_through", (wrap last)[1]?.getD nil),
        (b "segments", list (cursor.catalog ++ cursor.entries.reverse))] := by
  unfold complete at h
  split at h
  · simp [a] at h
  · rename_i last earlier entries
    simp only [Prod.mk.injEq, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at h
    exact ⟨last, earlier, entries, h.symm⟩

def Scope (cursor : Cursor) : Term × Term × Nat × List Term :=
  (cursor.agent, cursor.session, cursor.line, cursor.catalog)

theorem failed_not_resident {reason request : Term} {cursor : Cursor}
    (h : failed reason = (some cursor, request)) : False := by
  have impossible := congrArg Prod.fst h
  cases impossible

theorem propose_scope {cursor next : Cursor} {request : Term}
    (h : propose cursor = (some next, request)) : Scope next = Scope cursor := by
  obtain ⟨_, _, _, _, _, _, rfl, _, _⟩ := propose_request h
  rfl

theorem compare_scope {cursor next : Cursor} {records : List Term} {request : Term}
    (h : compare cursor records = (some next, request)) : Scope next = Scope cursor := by
  unfold compare at h
  split at h
  · exact (failed_not_resident h).elim
  · cases h
    rfl

theorem advance_scope {cursor next : Cursor} {records : List Term} {entry request : Term}
    (h : advance cursor records entry = (some next, request)) : Scope next = Scope cursor := by
  obtain ⟨rfl, _⟩ := proceed_request h
  rfl

/-- Storage observations cannot change the captured owner, size target, or old catalog. -/
theorem resume_scope {cursor next : Cursor} {result request : Term}
    (h : resume cursor result = (some next, request)) : Scope next = Scope cursor := by
  unfold resume at h
  repeat' first
    | exact propose_scope h
    | exact compare_scope h
    | exact advance_scope h
    | exact (failed_not_resident h).elim
    | split at h
    | dsimp only at h

inductive CursorReachable (initial : Cursor) : Cursor → Prop where
  | initial : CursorReachable initial initial
  | step (before : CursorReachable initial cursor)
      (execution : resume cursor result = (some next, request)) : CursorReachable initial next

theorem reachable_scope {initial cursor : Cursor} (reachable : CursorReachable initial cursor) :
    Scope cursor = Scope initial := by
  induction reachable with
  | initial => rfl
  | step _ execution ih => exact (resume_scope execution).trans ih

end VerifiedKernel.Session.ArchivePublication
