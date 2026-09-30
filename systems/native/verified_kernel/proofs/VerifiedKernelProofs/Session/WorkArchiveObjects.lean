import VerifiedKernelProofs.Session.WorkArchivePublication
import VerifiedKernelProofs.Session.WorkArchiveInput

namespace VerifiedKernel.Session.ArchivePublication
open Data
open WorkConservation WorkConservation.ValueSemantics
set_option Elab.async false

/-- Decoded immutable object facts at the storage adapter's logical address. -/
abbrev Objects := Term → List Term → Prop

def key (agent session first : Term) : Term := .tuple [agent, session, first]

def address (cursor : Cursor) : Term :=
  key cursor.agent cursor.session (((cursor.remaining.head?).getD nil).get (a "seq"))

/-- Successful create-once observations store the requested encoded value at the requested address.
This is the storage and codec primitive contract, not an application acceptance premise. -/
def CreateMeaning (request result : Term) (objects : Objects) : Prop :=
  ∀ agent session first bytes records,
    request = .tuple [a "create_segment", agent, session, first, .binary bytes] →
    ETF.encode (list records) = .ok bytes →
    (result = a "created" ∨ result = a "landed") →
    objects (key agent session first) records

def ReadMeaning (request result : Term) (objects : Objects) : Prop :=
  ∀ agent session first records,
    request = .tuple [a "read_segment", agent, session, first] →
    result = .tuple [a "ok", list records] → objects (key agent session first) records

def ExistingMeaning (request result : Term) (objects : Objects) : Prop :=
  ∀ agent session first bytes records,
    request = .tuple [a "create_segment", agent, session, first, .binary bytes] →
    result = .tuple [a "exists", list records] → objects (key agent session first) records

/-- The two requested values survive their codec round trips. Equality remains a kernel decision. -/
def CodecMeaning (request result : Term) : Prop :=
  ∀ left right,
    request = .tuple [a "request_batch", list [
      .tuple [a "deterministic_etf", left], .tuple [a "deterministic_etf", right]]] →
    ∃ (decode : ByteArray → Term) (first last : ByteArray),
      result = list [.binary first, .binary last] ∧
      Equivalent left (decode first) ∧ Equivalent right (decode last)

def CatalogBacked (objects : Objects) (agent session catalogEntry : Term) : Prop :=
  ∃ records count,
    objects (key agent session (((records.head?).getD nil).get (a "seq"))) records ∧
    catalogEntry = entry records count

theorem prefix_first {records selected : List Term}
    (nonempty : selected ≠ []) (partition : records = selected ++ records.drop selected.length) :
    ((records.head?).getD nil).get (a "seq") = ((selected.head?).getD nil).get (a "seq") := by
  cases selected with
  | nil => exact (nonempty rfl).elim
  | cons first rest => rw [partition]; rfl

/-- A positive create response binds the actual prefix, bytes, object address, and catalog entry. -/
theorem created_catalog_fact {cursor pending : Cursor} {request result : Term} {objects : Objects}
    (issued : propose cursor = (some pending, request))
    (primitive : CreateMeaning request result objects)
    (confirmed : result = a "created" ∨ result = a "landed") :
    ∃ records count bytes,
      ETF.encode (list records) = .ok bytes ∧
      request = objectRequest cursor "create_segment" [.binary bytes] ∧
      objects (address cursor) records ∧ CatalogBacked objects cursor.agent cursor.session (entry records count) ∧
      cursor.remaining = records ++ cursor.remaining.drop records.length ∧
      resume pending result = advance pending records (entry records count) := by
  obtain ⟨records, count, bytes, _, nonempty, encoded, pendingEq, requestEq, partition⟩ := propose_request issued
  have stored : objects (address cursor) records :=
    primitive cursor.agent cursor.session _ bytes records (by rw [requestEq]; rfl) encoded confirmed
  have located := stored
  unfold address at located
  rw [prefix_first nonempty partition] at located
  refine ⟨records, count, bytes, encoded, requestEq, stored, ⟨records, count, located, rfl⟩, partition, ?_⟩
  rw [pendingEq]
  rcases confirmed with rfl | rfl <;> rfl

theorem read_object_fact {cursor : Cursor} {records : List Term} {objects : Objects}
    (primitive : ReadMeaning (objectRequest cursor "read_segment")
      (.tuple [a "ok", list records]) objects) : objects (address cursor) records :=
  primitive cursor.agent cursor.session _ records rfl rfl

theorem existing_object_fact {cursor : Cursor} {bytes : ByteArray} {records : List Term} {objects : Objects}
    (primitive : ExistingMeaning (objectRequest cursor "create_segment" [.binary bytes])
      (.tuple [a "exists", list records]) objects) : objects (address cursor) records :=
  primitive cursor.agent cursor.session _ bytes records rfl rfl

theorem canonical_sequence (record : Term) :
    (ArchiveMatch.canonical record).get (a "seq") = record.get (a "seq") := by
  unfold ArchiveMatch.canonical
  dsimp only
  split
  · split
    · exact get_put_other _ _ (by decide)
    · rfl
  · rfl

theorem validate_first {records : List Term} (valid : validate records none = true) :
    ∃ first rest seq, records = first :: rest ∧ first.get (a "seq") = i seq := by
  cases records with
  | nil => cases valid
  | cons first rest =>
    cases value : first.get (a "seq") with
    | integer seq => exact ⟨first, rest, seq, rfl, value⟩
    | _ => simp [validate, value] at valid

/-- Exact prefix comparison binds the landed object's first sequence to its requested address. -/
theorem matched_first {landed window : List Term}
    (valid : validate landed none = true)
    (same : Equivalent (list (landed.map ArchiveMatch.canonical))
      (list ((window.take landed.length).map ArchiveMatch.canonical))) :
    ((window.head?).getD nil).get (a "seq") = ((landed.head?).getD nil).get (a "seq") := by
  obtain ⟨first, rest, seq, rfl, stamp⟩ := validate_first valid
  cases window with
  | nil =>
    have impossible := same.shape
    simp [shape, list] at impossible
  | cons expected tail =>
    have fields := (same.access (.index 0)).get (a "seq")
    change Equivalent ((ArchiveMatch.canonical first).get (a "seq"))
      ((ArchiveMatch.canonical expected).get (a "seq")) at fields
    rw [canonical_sequence, canonical_sequence, stamp] at fields
    change expected.get (a "seq") = first.get (a "seq")
    rw [stamp]
    exact fields.integer

theorem measured_entry_fields {records : List Term} {catalogEntry : Term}
    (measured : measuredEntry records = .ok catalogEntry) :
    ∃ bytes, catalogEntry = entry records bytes := by
  unfold measuredEntry at measured
  generalize records.foldlM (fun (count : Nat) record => (do
    let raw ← ETF.encode record
    return count + raw.size : Except String Nat)) 0 = sizes at measured
  cases sizes with
  | error reason => simp [bind, Except.bind] at measured
  | ok bytes =>
    simp only [bind, Except.bind, pure, Except.pure, Except.ok.injEq] at measured
    exact ⟨bytes, measured.symm⟩

theorem matched_catalog_fact {cursor : Cursor} {landed : List Term} {catalogEntry : Term} {objects : Objects}
    (stored : objects (address cursor) landed)
    (valid : validate landed none = true)
    (same : Equivalent (list (landed.map ArchiveMatch.canonical))
      (list ((cursor.remaining.take landed.length).map ArchiveMatch.canonical)))
    (measured : measuredEntry landed = .ok catalogEntry) :
    CatalogBacked objects cursor.agent cursor.session catalogEntry := by
  obtain ⟨bytes, entryEq⟩ := measured_entry_fields measured
  unfold address at stored
  rw [matched_first valid same] at stored
  exact ⟨landed, bytes, stored, entryEq⟩

def NonError (output : Output) : Prop := ∀ reason, output.2 ≠ .tuple [a "error", reason]

theorem error_is_error {reason : Term} {output : Output}
    (h : failed reason = output) (success : NonError output) : False :=
  success reason (by rw [← h]; rfl)

theorem comparison_prepared {cursor next : Cursor} {records : List Term} {request : Term}
    (h : compare cursor records = (some next, request)) :
    validate records none = true ∧ next = { cursor with phase := .compare records } ∧
      request = ArchiveMatch.request records (cursor.remaining.take records.length) := by
  unfold compare at h
  split at h
  · exact (failed_not_resident h).elim
  · rename_i valid
    cases h
    exact ⟨by simpa using valid, rfl, rfl⟩

/-- Continuing a comparison requires the actual byte check to succeed before the entry is measured and appended. -/
theorem compared_transition {cursor : Cursor} {records : List Term} {result : Term} {output : Output}
    (phase : cursor.phase = .compare records)
    (h : resume cursor result = output) (success : NonError output) :
    ∃ catalogEntry,
      ArchiveMatch.check nil (.tuple [list records, list (cursor.remaining.take records.length)])
        [.tuple [a "ok", result]] = .ok (a "ok", []) ∧
      measuredEntry records = .ok catalogEntry ∧ output = advance cursor records catalogEntry := by
  unfold resume at h
  simp only [phase] at h
  split at h
  · rename_i checked
    cases measured : measuredEntry records with
    | error reason =>
      simp only [measured] at h
      exact (error_is_error h success).elim
    | ok catalogEntry =>
      simp only [measured] at h
      exact ⟨catalogEntry, checked, rfl, h.symm⟩
  · exact (error_is_error h success).elim
  · exact (error_is_error h success).elim
  · exact (error_is_error h success).elim

theorem comparison_values {cursor : Cursor} {records : List Term} {result : Term}
    (codec : CodecMeaning (ArchiveMatch.request records (cursor.remaining.take records.length)) result)
    (checked : ArchiveMatch.check nil (.tuple [list records, list (cursor.remaining.take records.length)])
      [.tuple [a "ok", result]] = .ok (a "ok", [])) :
    Equivalent (list (records.map ArchiveMatch.canonical))
      (list ((cursor.remaining.take records.length).map ArchiveMatch.canonical)) := by
  obtain ⟨bytes, rest, read, bound⟩ := archive_match_success checked
  have observed := observe_recorded
    (ArchiveMatch.request records (cursor.remaining.take records.length)) result [] rfl
  rw [observed] at read
  have resultEq := (Prod.mk.inj (Except.ok.inj read)).1
  obtain ⟨decode, first, last, encoded, left, right⟩ := codec _ _ rfl
  rw [encoded] at resultEq
  simp only [list, Term.list.injEq, List.cons.injEq, Term.binary.injEq, and_true] at resultEq
  obtain ⟨rfl, rfl⟩ := resultEq
  have same := left.trans right.symm
  simpa only [List.take_of_length_le bound, List.take_take, Nat.min_self] using same

/-- An adopted catalog entry is backed by the read object at the same address, after actual codec comparison. -/
theorem adopted_catalog_fact {cursor : Cursor} {records : List Term} {result : Term}
    {output : Output} {objects : Objects}
    (phase : cursor.phase = .compare records)
    (stored : objects (address cursor) records)
    (valid : validate records none = true)
    (codec : CodecMeaning (ArchiveMatch.request records (cursor.remaining.take records.length)) result)
    (h : resume cursor result = output) (success : NonError output) :
    ∃ catalogEntry, CatalogBacked objects cursor.agent cursor.session catalogEntry ∧
      output = advance cursor records catalogEntry ∧
      Equivalent (list (records.map ArchiveMatch.canonical))
        (list ((cursor.remaining.take records.length).map ArchiveMatch.canonical)) := by
  obtain ⟨catalogEntry, checked, measured, advanced⟩ := compared_transition phase h success
  have same := comparison_values codec checked
  exact ⟨catalogEntry, matched_catalog_fact stored valid same measured, advanced, same⟩

theorem adopted_input_fact {cursor : Cursor} {records : List Term} {result item record projected : Term}
    {output : Output} {objects : Objects}
    (phase : cursor.phase = .compare records)
    (stored : objects (address cursor) records)
    (valid : validate records none = true)
    (codec : CodecMeaning (ArchiveMatch.request records (cursor.remaining.take records.length)) result)
    (h : resume cursor result = output) (success : NonError output)
    (projection : ArchiveProjection.MessageRecord record projected)
    (recorded : Recorded item record)
    (removed : projected ∈ cursor.remaining.take records.length) :
    ∃ landed ∈ records, Equivalent (queueWorkProjection item)
      ((landed.get (a "data")).get (b "accepted_input")) := by
  obtain ⟨_, _, _, same⟩ := adopted_catalog_fact phase stored valid codec h success
  exact matched_archive_input_fact projection recorded removed same

theorem created_input_fact {cursor pending : Cursor} {request result item record projected : Term}
    {objects : Objects}
    (issued : propose cursor = (some pending, request))
    (primitive : CreateMeaning request result objects)
    (confirmed : result = a "created" ∨ result = a "landed")
    (projection : ArchiveProjection.MessageRecord record projected)
    (recorded : Recorded item record) :
    ∃ records catalogEntry,
      objects (address cursor) records ∧ CatalogBacked objects cursor.agent cursor.session catalogEntry ∧
      resume pending result = advance pending records catalogEntry ∧
      (projected ∈ cursor.remaining.take records.length →
        projected ∈ records ∧ Equivalent (queueWorkProjection item)
          ((projected.get (a "data")).get (b "accepted_input"))) := by
  obtain ⟨records, count, _, _, _, stored, backed, partition, advanced⟩ :=
    created_catalog_fact issued primitive confirmed
  refine ⟨records, entry records count, stored, backed, advanced, ?_⟩
  intro removed
  have prefixEq : cursor.remaining.take records.length = records := by
    rw [partition]
    simp
  rw [prefixEq] at removed
  exact ⟨removed, projection.input_fact recorded⟩

end VerifiedKernel.Session.ArchivePublication
