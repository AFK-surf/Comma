import VerifiedKernelProofs.Session.WorkSemanticExecution
import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernel.Session.Query.Storage

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

namespace ArchiveProjection

def projectRecord (fieldName : String) (seqKey : Term) (kind : String) (record : Term) : KernelM (Option Term) := do
  let seq ← access record seqKey
  let kind := if fieldName == "async_results" then
    (record.get (b "kind")).default (b kind) else b kind
  if !seq.isInteger || !kind.isBinary then return none
  let data ← stringify (← remove (← remove record (a "seq")) (b "seq"))
  return some (.map [(a "seq", seq), (a "kind", kind), (a "data", data)])

def collectRecords (state : Term) (fieldName : String) (seqKey : Term) (kind : String) : KernelM (List Term) := do
  let records ← asList ((← field state fieldName).default (list []))
  records.filterMapM (projectRecord fieldName seqKey kind)

theorem windowRecords_eq (state : Term) : StorageQuery.windowRecords state = (do
    let messages ← collectRecords state "messages" (a "seq") "message"
    let events ← collectRecords state "events" (b "seq") "fact"
    let results ← collectRecords state "async_results" (b "seq") "async_result"
    return list (← sortBy (messages ++ events ++ results) (fun record => pure (record.get (a "seq"))))) := rfl

def MessageRecord (original projected : Term) : Prop :=
  ∃ withoutAtom withoutBinary payload first second third last,
    remove original (a "seq") first = .ok (withoutAtom, second) ∧
    remove withoutAtom (b "seq") second = .ok (withoutBinary, third) ∧
    stringify withoutBinary third = .ok (payload, last) ∧
    projected = .map [(a "seq", original.get (a "seq")), (a "kind", b "message"), (a "data", payload)]

theorem message_projected {record : Term} {output : Option Term} {stamp : Int} {j r : List Term}
    (seq : record.get (a "seq") = i stamp)
    (h : projectRecord "messages" (a "seq") "message" record j = .ok (output, r)) :
    ∃ projected, output = some projected ∧ MessageRecord record projected := by
  unfold projectRecord at h
  obtain ⟨value, _, read, h⟩ := bind_ok h
  have same := (access_ok read).1
  subst value
  simp only [seq] at h
  simp +decide only [Term.isInteger, Term.isBinary, b, Term.text, Bool.not_true,
    Bool.false_or, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨withoutAtom, second, removedAtom, h⟩ := bind_ok h
  obtain ⟨withoutBinary, third, removedBinary, h⟩ := bind_ok h
  obtain ⟨payload, last, normalized, h⟩ := bind_ok h
  have result := pure_ok h
  refine ⟨_, result, withoutAtom, withoutBinary, payload, _, second, third, last,
    removedAtom, removedBinary, normalized, ?_⟩
  rw [seq]
  rfl

theorem filterMapM_covers {f : Term → KernelM (Option Term)} {xs ys : List Term}
    {record : Term} {j r : List Term}
    (present : record ∈ xs)
    (kept : ∀ output first last, f record first = .ok (output, last) →
      ∃ projected, output = some projected ∧ MessageRecord record projected)
    (h : xs.filterMapM f j = .ok (ys, r)) :
    ∃ projected ∈ ys, MessageRecord record projected := by
  induction xs generalizing ys j r with
  | nil => simp at present
  | cons head tail ih =>
    rw [List.filterMapM_cons] at h
    obtain ⟨output, nextJournal, first, h⟩ := bind_ok h
    rcases List.mem_cons.mp present with equal | member
    · subst head
      obtain ⟨projected, outputEq, fields⟩ := kept output j nextJournal first
      subst output
      obtain ⟨rest, _, _, h⟩ := bind_ok h
      rw [pure_ok h]
      exact ⟨projected, List.mem_cons_self, fields⟩
    · cases output with
      | none => exact ih member h
      | some projected =>
        obtain ⟨rest, _, restRead, h⟩ := bind_ok h
        obtain ⟨found, member, fields⟩ := ih member restRead
        rw [pure_ok h]
        exact ⟨found, List.mem_cons_of_mem _ member, fields⟩

theorem collect_messages {s record : Term} {live projected : List Term} {stamp : Int} {j r : List Term}
    (read : s.get (a "messages") = list live) (member : record ∈ live)
    (seq : record.get (a "seq") = i stamp)
    (h : collectRecords s "messages" (a "seq") "message" j = .ok (projected, r)) :
    ∃ next ∈ projected, MessageRecord record next := by
  unfold collectRecords at h
  obtain ⟨records, _, recordsRead, h⟩ := bind_ok h
  have same := field_value recordsRead
  rw [read] at same
  subst records
  obtain ⟨values, _, valuesRead, h⟩ := bind_ok h
  have same := pure_ok valuesRead
  subst values
  exact filterMapM_covers member (fun _ _ _ call => message_projected seq call) h

theorem window_contains_messages {s record : Term} {live records : List Term} {j r : List Term}
    (inv : SeqSorted s) (read : s.get (a "messages") = list live) (member : record ∈ live)
    (h : StorageQuery.windowRecords s j = .ok (list records, r)) :
    ∃ projected ∈ records, MessageRecord record projected := by
  obtain ⟨messages, ceiling, messagesRead, _, stamped, _⟩ := inv
  have same := Term.list.inj (messagesRead.symm.trans read)
  subst messages
  obtain ⟨stamp, seq, _⟩ := stamped record member
  rw [windowRecords_eq] at h
  obtain ⟨projectedMessages, _, projected, h⟩ := bind_ok h
  obtain ⟨events, _, _, h⟩ := bind_ok h
  obtain ⟨results, _, _, h⟩ := bind_ok h
  obtain ⟨sorted, _, ordered, h⟩ := bind_ok h
  have same := Term.list.inj (pure_ok h)
  subst sorted
  obtain ⟨next, present, fields⟩ := collect_messages read member seq projected
  exact ⟨next, (sortBy_permutation ordered).mem_iff.mpr
    (List.mem_append_left _ (List.mem_append_left _ present)), fields⟩

/-- PG constructs the publication input from records strictly after its captured frontier. -/
def UnarchivedWindow (state : Term) : Prop :=
  ∃ base : Int, (state.get (a "archived_through")).default (i 0) = i base ∧
    ∀ record, ContainsRecord state record → base < integerValue (record.get (a "seq"))

theorem MessageRecord.sequence {record projected : Term} (projection : MessageRecord record projected) :
    projected.get (a "seq") = record.get (a "seq") := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, equal⟩ := projection
  rw [equal]
  rfl

theorem filterAuxM_contains {f : Term → KernelM Bool} {xs acc ys : List Term}
    {record : Term} {j r : List Term}
    (present : record ∈ xs ∨ record ∈ acc) (kept : Runs f record true)
    (h : List.filterAuxM f xs acc j = .ok (ys, r)) : record ∈ ys := by
  induction xs generalizing acc j with
  | nil =>
    simp only [List.filterAuxM, pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
    exact present.resolve_left (by simp)
  | cons head tail ih =>
    simp only [List.filterAuxM] at h
    obtain ⟨value, middle, call, h⟩ := bind_ok h
    cases value with
    | false =>
      apply ih (acc := acc) (j := middle) _ h
      rcases present with member | member
      · rcases List.mem_cons.mp member with equal | later
        · subst head
          rw [kept j] at call
          simp at call
        · exact Or.inl later
      · exact Or.inr member
    | true =>
      apply ih (acc := head :: acc) (j := middle) _ h
      rcases present with member | member
      · rcases List.mem_cons.mp member with equal | later
        · subst head
          exact Or.inr (List.mem_cons_self ..)
        · exact Or.inl later
      · exact Or.inr (List.mem_cons_of_mem _ member)

theorem filterM_contains {f : Term → KernelM Bool} {xs ys : List Term}
    {record : Term} {j r : List Term} (present : record ∈ xs) (kept : Runs f record true)
    (h : xs.filterM f j = .ok (ys, r)) : record ∈ ys := by
  unfold List.filterM at h
  obtain ⟨reversed, _, filtered, h⟩ := bind_ok h
  rw [pure_ok h]
  exact List.mem_reverse.mpr (filterAuxM_contains (Or.inl present) kept filtered)

theorem archiveWindow_records {s ceiling : Term} {records : List Term} {j r : List Term}
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected first last middle final,
      StorageQuery.windowRecords s first = .ok (list projected, last) ∧
      projected.filterM (fun record => greater (record.get (a "seq"))
        ((s.get (a "archived_through")).default (i 0))) middle = .ok (records, final) := by
  unfold StorageQuery.archiveWindow at h
  obtain ⟨stored, _, storedRead, h⟩ := bind_ok h
  obtain ⟨_, afterCeiling, _, h⟩ := bind_ok h
  obtain ⟨raw, afterProjection, projectedRead, h⟩ := bind_ok h
  obtain ⟨projected, afterList, listed, h⟩ := bind_ok h
  obtain ⟨selected, afterFilter, filtered, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · have impossible := pure_ok h
    simp [a, Term.tuple.injEq] at impossible
  · have equal := pure_ok h
    simp only [Term.tuple.injEq, List.cons.injEq, Term.list.injEq, true_and, and_true] at equal
    have same : records = selected := Term.list.inj equal.1
    subst records
    have rawEq := (asList_ok_iff.mp listed).1
    rw [rawEq] at projectedRead
    rw [field_value storedRead] at filtered
    exact ⟨projected, afterCeiling, afterProjection, afterList, afterFilter, projectedRead, filtered⟩

theorem archiveWindow_messages {s record ceiling : Term} {live records : List Term} {j r : List Term}
    (inv : SeqSorted s) (physical : UnarchivedWindow s)
    (read : s.get (a "messages") = list live) (member : record ∈ live)
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records, MessageRecord record projected := by
  obtain ⟨all, _, _, _, _, projected, filtered⟩ := archiveWindow_records h
  obtain ⟨next, included, image⟩ := window_contains_messages inv read member projected
  refine ⟨next, filterM_contains included ?_ filtered, image⟩
  obtain ⟨base, numeric, above⟩ := physical
  obtain ⟨messages, _, messageRead, _, stamped, _⟩ := inv
  have same := Term.list.inj (messageRead.symm.trans read)
  subst messages
  obtain ⟨stamp, seq, _⟩ := stamped record member
  have ahead := above record ⟨live, read, member⟩
  rw [seq] at ahead
  simp only [integerValue, i] at ahead
  intro journal
  change greater (next.get (a "seq")) ((s.get (a "archived_through")).default (i 0)) journal = _
  rw [image.sequence, seq, numeric]
  simpa [i, ahead] using greater_integer stamp base journal

theorem removed_records_projected {s e t ceiling : Term} {live records j r first last : List Term}
    (inv : SeqSorted s) (physical : UnarchivedWindow s) (read : s.get (a "messages") = list live)
    (plain : ∀ record ∈ live, (record.isMap && !record.has (a "__struct__")) = true)
    (window : StorageQuery.archiveWindow s first = .ok (.tuple [a "ok", list records, ceiling], last))
    (advance : archiveAdvance s e j = .ok (t, r)) :
    ∃ dropped kept, live = dropped ++ kept ∧ t.get (a "messages") = list kept ∧
      ∀ record ∈ dropped, ∃ projected ∈ records, MessageRecord record projected := by
  obtain ⟨dropped, kept, partition, after, _⟩ := archiveAdvance_prefix inv read plain advance
  refine ⟨dropped, kept, partition, after, ?_⟩
  intro record member
  apply archiveWindow_messages inv physical read _ window
  rw [partition]
  exact List.mem_append_left _ member

end ArchiveProjection
end VerifiedKernel.Session.WorkConservation
