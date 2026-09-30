import VerifiedKernelProofs.Session.WorkArchiveInitial
import VerifiedKernelProofs.Session.WorkFillDefaults

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace ReloadSequence
set_option Elab.async false
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096

def NumericRecords (records key : Term) : Prop :=
  ∃ items, records = list items ∧
    ∀ item ∈ items, ∃ n : Int, (item.get key).default (i 0) = i n

def HistoryNumbers (state : Term) : Prop :=
  NumericRecords (state.get (a "messages")) (a "seq") ∧
  NumericRecords (state.get (a "events")) (b "seq") ∧
  NumericRecords (state.get (a "async_results")) (b "seq") ∧
  ∃ n : Int, lastSeq state = i n

def NumericOption : Option Term → Prop
  | none => True
  | some value => ∃ n : Int, value = i n

def stampStep (key : Term) (current : Option Term) (record : Term) : KernelM (Option Term) := do
  let stamp := (← access record key).default (i 0)
  match current with
  | none => pure (some stamp)
  | some previous => pure (some (if ← less stamp previous then previous else stamp))

def stampRecords (records key : Term) (initial : Option Term) : KernelM (Option Term) :=
  enumFold records initial (stampStep key)

theorem maxStamped_eq (messages events results : Term) : Lifecycle.maxStamped messages events results = (do
    let ms ← stampRecords messages (a "seq") none
    let es ← stampRecords events (b "seq") ms
    let rs ← stampRecords results (b "seq") es
    return rs.getD (i 0)) := rfl

theorem stampStep_numeric {key record : Term} {initial final : Option Term} {j r : List Term}
    (before : NumericOption initial)
    (numeric : ∃ n : Int, (record.get key).default (i 0) = i n)
    (h : stampStep key initial record j = .ok (final, r)) : NumericOption final := by
  unfold stampStep at h
  obtain ⟨value, _, read, h⟩ := bind_ok h
  have same := (access_ok read).1
  subst value
  cases initial with
  | none => rw [pure_ok h]; exact numeric
  | some previous =>
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · rw [pure_ok h]; exact before
    · rw [pure_ok h]; exact numeric

theorem stampRecords_numeric {records key : Term} {initial final : Option Term} {j r : List Term}
    (before : NumericOption initial) (numeric : NumericRecords records key)
    (h : stampRecords records key initial j = .ok (final, r)) : NumericOption final := by
  obtain ⟨items, rfl, numeric⟩ := numeric
  obtain ⟨enumerated, folded, enumeration⟩ := enumFold_ok h
  rw [enumeration _ rfl] at folded
  clear enumeration h
  induction items generalizing initial j with
  | nil => rw [pure_ok folded]; exact before
  | cons item items ih =>
    rw [List.foldlM_cons] at folded
    obtain ⟨next, _, first, rest⟩ := bind_ok folded
    exact ih (stampStep_numeric before (numeric item List.mem_cons_self) first)
      (fun record member => numeric record (List.mem_cons_of_mem _ member)) rest

theorem maxStamped_numeric {messages events results value : Term} {j r : List Term}
    (ms : NumericRecords messages (a "seq")) (es : NumericRecords events (b "seq"))
    (rs : NumericRecords results (b "seq"))
    (h : Lifecycle.maxStamped messages events results j = .ok (value, r)) :
    ∃ n : Int, value = i n := by
  rw [maxStamped_eq] at h
  obtain ⟨first, _, firstCall, h⟩ := bind_ok h
  have firstNumbers := stampRecords_numeric (initial := none) trivial ms firstCall
  obtain ⟨second, _, secondCall, h⟩ := bind_ok h
  have secondNumbers := stampRecords_numeric firstNumbers es secondCall
  obtain ⟨third, _, thirdCall, h⟩ := bind_ok h
  have thirdNumbers := stampRecords_numeric secondNumbers rs thirdCall
  rw [pure_ok h]
  cases third with
  | none => exact ⟨0, rfl⟩
  | some term => exact thirdNumbers

theorem NumericRecords.default {records key fallback : Term} (numbers : NumericRecords records key) :
    NumericRecords (records.default fallback) key := by
  obtain ⟨items, rfl, numeric⟩ := numbers
  exact ⟨items, rfl, numeric⟩

theorem normalizeLastSeq_bound {state value : Term} {n : Int} {j r : List Term}
    (stored : lastSeq state = i n)
    (ms : NumericRecords (state.get (a "messages")) (a "seq"))
    (es : NumericRecords (state.get (a "events")) (b "seq"))
    (rs : NumericRecords (state.get (a "async_results")) (b "seq"))
    (h : Lifecycle.normalizeLastSeq state j = .ok (value, r)) :
    ∃ next : Int, value = i next ∧ n ≤ next := by
  unfold Lifecycle.normalizeLastSeq at h
  obtain ⟨previous, _, previousRead, h⟩ := bind_ok h
  have same := field_value previousRead
  subst previous
  obtain ⟨messages, _, messagesRead, h⟩ := bind_ok h
  have same := field_value messagesRead
  subst messages
  obtain ⟨events, _, eventsRead, h⟩ := bind_ok h
  have same := field_value eventsRead
  subst events
  obtain ⟨results, _, resultsRead, h⟩ := bind_ok h
  have same := field_value resultsRead
  subst results
  obtain ⟨stamped, _, stampedRead, h⟩ := bind_ok h
  obtain ⟨highest, rfl⟩ := maxStamped_numeric ms.default es.default rs.default stampedRead
  change kmax (lastSeq state) (i highest) _ = .ok (value, r) at h
  rw [stored, kmax_integer] at h
  exact ⟨max n highest, (Prod.mk.inj (Except.ok.inj h)).1.symm, Int.le_max_left _ _⟩

theorem NumericRecords.not_nil {records key : Term} (numbers : NumericRecords records key) : records ≠ nil := by
  obtain ⟨items, rfl, _⟩ := numbers
  intro impossible
  cases impossible

theorem HistoryNumbers.fillDefaults {state : Term} (numbers : HistoryNumbers state) :
    HistoryNumbers (Lifecycle.fillDefaults state) := by
  obtain ⟨messages, events, results, n, stored⟩ := numbers
  refine ⟨?_, ?_, ?_, n, ?_⟩
  · rw [fillDefaults_get messages.not_nil]; exact messages
  · rw [fillDefaults_get events.not_nil]; exact events
  · rw [fillDefaults_get results.not_nil]; exact results
  · exact (fillDefaults_lastSeq state).trans stored

theorem normalize_history_fields {s t : Term} {j r : List Term}
    (h : Lifecycle.normalize s j = .ok (t, r)) :
    t.get (a "messages") = ((Lifecycle.fillDefaults s).get (a "messages")).default (list []) ∧
    t.get (a "events") = ((Lifecycle.fillDefaults s).get (a "events")).default (list []) ∧
    t.get (a "async_results") = ((Lifecycle.fillDefaults s).get (a "async_results")).default (list []) := by
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_field_is h "messages"; change (field (Lifecycle.fillDefaults s) "messages" >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨messages, _, messagesRead, h⟩ := bind_ok h
  have same := field_value messagesRead
  subst messages
  obtain ⟨events, _, eventsRead, h⟩ := bind_ok h
  have same := field_value eventsRead
  subst events
  repeat
    fail_if_success (bind_field_is h "async_results"; change (field (Lifecycle.fillDefaults s) "async_results" >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨results, _, resultsRead, h⟩ := bind_ok h
  have same := field_value resultsRead
  subst results
  repeat
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have messagesWritten := write_get_key "messages" written rfl
  have eventsWritten := write_get_key "events" written rfl
  have resultsWritten := write_get_key "async_results" written rfl
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, providersWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  have frame : ∀ key : String, key ≠ "activity_status" → key ≠ "context_provider_states" → key ≠ "input_dedupe" →
      t.get (a key) = normalized.get (a key) := by
    intro key activity providers dedupe
    exact (write_field_frame h (by simp [Ne.symm dedupe])).trans
      ((write_field_frame providersWrite (by simp [Ne.symm providers])).trans
        (write_field_frame activityWrite (by simp [Ne.symm activity])))
  exact ⟨(frame "messages" (by decide) (by decide) (by decide)).trans messagesWritten,
    (frame "events" (by decide) (by decide) (by decide)).trans eventsWritten,
    (frame "async_results" (by decide) (by decide) (by decide)).trans resultsWritten⟩

theorem normalize_sequence {s t : Term} {j r : List Term}
    (numbers : HistoryNumbers s) (sorted : SeqSorted s)
    (h : Lifecycle.normalize s j = .ok (t, r)) : SeqSorted t ∧ HistoryNumbers t := by
  have filled := numbers.fillDefaults
  obtain ⟨n, stored⟩ := filled.2.2.2
  obtain ⟨value, first, last, actual, output⟩ := normalize_sequence_value h
  obtain ⟨next, valueEq, bound⟩ := normalizeLastSeq_bound stored filled.1 filled.2.1 filled.2.2.1 actual
  have fields := normalize_history_fields h
  have nextStored : t.get (a "last_seq") = i next := output.trans valueEq
  have nextNumbers : HistoryNumbers t := by
    refine ⟨?_, ?_, ?_, next, ?_⟩
    · rw [fields.1]; exact filled.1.default
    · rw [fields.2.1]; exact filled.2.1.default
    · rw [fields.2.2]; exact filled.2.2.1.default
    · rw [lastSeq, nextStored, default_integer]
  refine ⟨?_, nextNumbers⟩
  obtain ⟨messages, ceiling, read, watermark, stamped, ordered⟩ := sorted
  have ceilingEq : ceiling = n := Term.integer.inj
    (watermark.symm.trans ((fillDefaults_lastSeq s).symm.trans stored))
  have readFilled := fillDefaults_get (key := "messages") (s := s) (by rw [read]; intro impossible; cases impossible)
  refine ⟨messages, next, ?_, ?_, ?_, ordered⟩
  · rw [fields.1, readFilled, read]; rfl
  · rw [lastSeq, nextStored, default_integer]
  · intro message member
    obtain ⟨stamp, stampRead, below⟩ := stamped message member
    exact ⟨stamp, stampRead, Int.le_trans below (by simpa [ceilingEq] using bound)⟩

theorem build_history_numbers {entries : List (String × Term)}
    (ms : entries.all (fun pair => pair.1 != "messages") = true)
    (es : entries.all (fun pair => pair.1 != "events") = true)
    (rs : entries.all (fun pair => pair.1 != "async_results") = true)
    (last : entries.all (fun pair => pair.1 != "last_seq") = true) :
    HistoryNumbers (Lifecycle.build entries) := by
  refine ⟨⟨[], (build_get ms).trans rfl, by simp⟩,
    ⟨[], (build_get es).trans rfl, by simp⟩,
    ⟨[], (build_get rs).trans rfl, by simp⟩, 0, ?_⟩
  have stored : (Lifecycle.build entries).get (a "last_seq") = i 0 := (build_get last).trans rfl
  rw [lastSeq, stored, default_integer]

theorem empty_sorted {state : Term} (messages : state.get (a "messages") = list [])
    (last : state.get (a "last_seq") = i 0) : SeqSorted state := by
  refine ⟨[], 0, messages, ?_, by simp, List.Pairwise.nil⟩
  rw [lastSeq, last, default_integer]

theorem create_history_numbers {s args t : Term} {j r : List Term}
    (h : Lifecycle.create s args j = .ok (t, r)) : HistoryNumbers t := by
  unfold Lifecycle.create at h
  split at h
  · repeat
      fail_if_success (head_is h [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (t, r) at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    exact (normalize_sequence (build_history_numbers rfl rfl rfl rfl)
      (empty_sorted ((build_get rfl).trans rfl) ((build_get rfl).trans rfl)) h).2
  · exact (fail_ok h).elim

theorem codec_numeric_records {left right key : Term} (same : ValueSemantics.Equivalent left right)
    (numbers : NumericRecords left key) : NumericRecords right key := by
  obtain ⟨items, rfl, numeric⟩ := numbers
  obtain ⟨other, read, length, related⟩ := same.list
  refine ⟨other, read, ?_⟩
  intro item member
  obtain ⟨original, originalMember, equivalent⟩ := ValueSemantics.list_member length.symm
    (fun index => (related index).symm) member
  obtain ⟨n, stamp⟩ := numeric original originalMember
  have next := (equivalent.symm.get key).default (ValueSemantics.Equivalent.refl (i 0))
  rw [stamp] at next
  exact ⟨n, next.integer⟩

theorem codec_history_numbers {left right : Term} (same : ValueSemantics.Equivalent left right)
    (numbers : HistoryNumbers left) : HistoryNumbers right := by
  obtain ⟨ms, es, rs, n, stored⟩ := numbers
  refine ⟨codec_numeric_records (same.get _) ms, codec_numeric_records (same.get _) es,
    codec_numeric_records (same.get _) rs, n, ?_⟩
  have field := (same.get (a "last_seq")).default (ValueSemantics.Equivalent.refl (i 0))
  change ValueSemantics.Equivalent (lastSeq left) (lastSeq right) at field
  rw [stored] at field
  exact field.integer

theorem load_trace_sequence {resident : Option Term} {s t : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (ready : QueueReady s) (numbers : HistoryNumbers s) (sorted : SeqSorted s)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) : SeqSorted t ∧ HistoryNumbers t := by
  have initial : ReloadEvidence s (SessionDomain.dispatch resident
      (.tuple [i 1, a "session", i 1, a "load", .binary bytes])) := by
    rw [load_dispatch_normalization decoded (queueReady_isMap ready)]
    exact normalizedResponse_evidence s [] ready
  obtain ⟨_, _, normalized⟩ := (reload_trace_evidence trace ready initial).1 t rfl
  exact normalize_sequence numbers sorted normalized

end ReloadSequence
end VerifiedKernel.Session.WorkConservation
