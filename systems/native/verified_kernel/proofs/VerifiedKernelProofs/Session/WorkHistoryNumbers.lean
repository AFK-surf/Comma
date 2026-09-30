import VerifiedKernelProofs.Session.WorkReloadSequence
import VerifiedKernelProofs.Session.WorkAuxiliaryFrames
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent

namespace VerifiedKernel.Session.WorkConservation
open Data ReloadSequence
set_option Elab.async false
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096

def AuxiliaryNumbers (state : Term) : Prop :=
  NumericRecords (state.get (a "events")) (b "seq") ∧
  NumericRecords (state.get (a "async_results")) (b "seq")

def AuxiliaryStep (s t : Term) : Prop := SeqSorted s → AuxiliaryNumbers s → AuxiliaryNumbers t

theorem AuxiliaryFrame.numbers {s t : Term} (frame : AuxiliaryFrame s t)
    (numbers : AuxiliaryNumbers s) : AuxiliaryNumbers t := by
  simpa only [AuxiliaryNumbers, frame.1, frame.2] using numbers

theorem history_numbers_from_auxiliary {state : Term} (sorted : SeqSorted state)
    (numbers : AuxiliaryNumbers state) : HistoryNumbers state := by
  obtain ⟨messages, last, read, watermark, stamped, _⟩ := sorted
  refine ⟨⟨messages, read, ?_⟩, numbers.1, numbers.2, last, watermark⟩
  intro message member
  obtain ⟨n, stamp, _⟩ := stamped message member
  exact ⟨n, by rw [stamp, default_integer]⟩

theorem add_last_numeric {state value : Term} {j r : List Term} (sorted : SeqSorted state)
    (h : add (lastSeq state) (i 1) j = .ok (value, r)) : ∃ n : Int, value = i n := by
  obtain ⟨_, n, _, watermark, _⟩ := sorted
  rw [watermark, add_integer] at h
  exact ⟨n + 1, (Prod.mk.inj (Except.ok.inj h)).1.symm⟩

theorem numeric_append {records key message value : Term} {j r : List Term}
    (numbers : NumericRecords records key)
    (stamped : ∃ n : Int, (message.get key).default (i 0) = i n)
    (h : append records (list [message]) j = .ok (value, r)) : NumericRecords value key := by
  obtain ⟨items, rfl, numeric⟩ := numbers
  rw [pure_ok h]
  refine ⟨items ++ [message], rfl, ?_⟩
  intro record member
  rcases List.mem_append.mp member with old | added
  · exact numeric record old
  · obtain rfl := List.mem_singleton.mp added
    exact stamped

theorem binary_stamped_numeric (record : Term) (n : Int) :
    ∃ value : Int, ((record.put (b "seq") (i n)).get (b "seq")).default (i 0) = i value :=
  ⟨n, by rw [get_put_binary_same, default_integer]⟩

theorem write_events_numeric {s t records : Term} {entries : List (String × Term)} {j r : List Term}
    (before : AuxiliaryNumbers s) (numbers : NumericRecords records (b "seq"))
    (h : write s entries j = .ok (t, r))
    (selected : entries.reverse.find? (fun pair => pair.1 == "events") = some ("events", records))
    (retained : entries.all (fun pair => pair.1 != "async_results") = true) : AuxiliaryNumbers t := by
  refine ⟨?_, ?_⟩
  · rw [write_get_key "events" h selected]; exact numbers
  · rw [write_field_frame h retained]; exact before.2

theorem write_results_numeric {s t records : Term} {entries : List (String × Term)} {j r : List Term}
    (before : AuxiliaryNumbers s) (numbers : NumericRecords records (b "seq"))
    (h : write s entries j = .ok (t, r))
    (selected : entries.reverse.find? (fun pair => pair.1 == "async_results") = some ("async_results", records))
    (retained : entries.all (fun pair => pair.1 != "events") = true) : AuxiliaryNumbers t := by
  refine ⟨?_, ?_⟩
  · rw [write_field_frame h retained]; exact before.1
  · rw [write_get_key "async_results" h selected]; exact numbers

set_option backward.split false in
theorem sessionEvent_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  have frame := (sessionEvent_fields h).2
  unfold sessionEvent at h
  obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
  have same := field_value watermarkRead
  subst watermark
  obtain ⟨seq, _, incremented, h⟩ := bind_ok h
  obtain ⟨n, rfl⟩ := add_last_numeric sorted incremented
  repeat' first
    | (execution_head_is h "VerifiedKernel.Data.write"
       constructor
       · rw [write_get_key "events" h rfl]
         exact nextNumbers
       · rw [frame "async_results" rfl]
         exact numbers.2)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.field"
            have same := field_value prior
            subst value)
         | (execution_head_is prior "VerifiedKernel.Data.append"
            have nextNumbers := numeric_append numbers.1.default (binary_stamped_numeric _ n) prior)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem compactionRecovery_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : compactionRecovery s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold compactionRecovery at h
  obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
  have same := field_value watermarkRead
  subst watermark
  obtain ⟨seq, _, incremented, h⟩ := bind_ok h
  obtain ⟨n, rfl⟩ := add_last_numeric sorted incremented
  obtain ⟨events, _, eventsRead, h⟩ := bind_ok h
  have same := field_value eventsRead
  subst events
  obtain ⟨history, _, appended, h⟩ := bind_ok h
  have nextNumbers := numeric_append numbers.1.default (binary_stamped_numeric _ n) appended
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_events_numeric numbers nextNumbers h rfl rfl

theorem compactResult_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : compactResult s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold compactResult at h
  obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
  have same := field_value watermarkRead
  subst watermark
  obtain ⟨seq, _, incremented, h⟩ := bind_ok h
  obtain ⟨n, rfl⟩ := add_last_numeric sorted incremented
  repeat' (
    fail_if_success (bind_field_is h "events"; change (field s "events" >>= _) _ = _ at h)
    first | split at h | (obtain ⟨_, _, _, h⟩ := bind_ok h))
  all_goals
    obtain ⟨events, _, eventsRead, h⟩ := bind_ok h
    have same := field_value eventsRead
    subst events
    obtain ⟨history, _, appended, h⟩ := bind_ok h
    have nextNumbers := numeric_append numbers.1.default (binary_stamped_numeric _ n) appended
    repeat
      fail_if_success (bind_head_is h [write]; change (write s _ >>= _) _ = .ok (t, r) at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨updated, _, written, h⟩ := bind_ok h
    exact (pruneCompactResults_auxiliary_frame h).numbers
      (write_events_numeric numbers nextNumbers written rfl rfl)

theorem storedResult_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : storedResult s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold storedResult at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]; exact numbers
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · rw [pure_ok h]; exact numbers
    · obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
      have same := field_value watermarkRead
      subst watermark
      obtain ⟨seq, _, incremented, h⟩ := bind_ok h
      obtain ⟨n, rfl⟩ := add_last_numeric sorted incremented
      obtain ⟨results, _, resultsRead, h⟩ := bind_ok h
      have same := field_value resultsRead
      subst results
      obtain ⟨history, _, appended, h⟩ := bind_ok h
      have nextNumbers := numeric_append numbers.2.default (binary_stamped_numeric _ n) appended
      repeat
        fail_if_success (head_is h [write]; change write s _ _ = .ok (t, r) at h)
        obtain ⟨_, _, _, h⟩ := bind_ok h
      exact write_results_numeric numbers nextNumbers h rfl rfl

theorem asyncTerminal_auxiliary_numbers {s e status t : Term} {j r : List Term}
    (h : asyncTerminal s e status j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold asyncTerminal at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · rw [pure_ok h]; exact numbers
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
    have same := field_value watermarkRead
    subst watermark
    obtain ⟨seq, _, incremented, h⟩ := bind_ok h
    obtain ⟨n, rfl⟩ := add_last_numeric sorted incremented
    obtain ⟨results, _, resultsRead, h⟩ := bind_ok h
    have same := field_value resultsRead
    subst results
    obtain ⟨history, _, appended, h⟩ := bind_ok h
    have nextNumbers := numeric_append numbers.2.default (binary_stamped_numeric _ n) appended
    repeat'
      fail_if_success (bind_head_is h [write]; change (write s _ >>= _) _ = .ok (t, r) at h)
      first | split at h | obtain ⟨_, _, _, h⟩ := bind_ok h | dsimp only at h
    all_goals
      obtain ⟨updated, _, written, h⟩ := bind_ok h
      exact (noteAsyncResult_auxiliary_frame h).numbers
        (write_results_numeric numbers nextNumbers written rfl rfl)

theorem replyRepair_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : replyRepair s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold replyRepair at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨updated, _, written, h⟩ := bind_ok h
  have updatedSorted := write_seq_frame written rfl sorted
  have updatedNumbers := (write_auxiliary_frame written rfl rfl).numbers numbers
  obtain ⟨watermark, _, watermarkRead, h⟩ := bind_ok h
  have same := field_value watermarkRead
  subst watermark
  obtain ⟨seq, _, incremented, h⟩ := bind_ok h
  obtain ⟨n, rfl⟩ := add_last_numeric updatedSorted incremented
  obtain ⟨events, _, eventsRead, h⟩ := bind_ok h
  have same := field_value eventsRead
  subst events
  obtain ⟨history, _, appended, h⟩ := bind_ok h
  have nextNumbers := numeric_append updatedNumbers.1.default (binary_stamped_numeric _ n) appended
  repeat
    fail_if_success (head_is h [write]; change write updated _ _ = .ok (t, r) at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_events_numeric updatedNumbers nextNumbers h rfl rfl

theorem archiveAdvance_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : archiveAdvance s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro _ numbers
  obtain ⟨oldEvents, eventsRead, eventNumbers⟩ := numbers.1
  obtain ⟨oldResults, resultsRead, resultNumbers⟩ := numbers.2
  unfold archiveAdvance at h
  repeat' first
    | (fail_if_success (bind_field_is h "events"; change (field s "events" >>= _) _ = _ at h)
       first
         | (have same := pure_ok h; cases same; exact numbers)
         | split at h
         | (obtain ⟨_, _, _, h⟩ := bind_ok h))
  all_goals
    obtain ⟨events, _, readEvents, h⟩ := bind_ok h
    have same := (field_value readEvents).trans eventsRead
    subst events
    obtain ⟨mappedEvents, _, mapped, h⟩ := bind_ok h
    change enumMap (list oldEvents) pure _ = _ at mapped
    have same := (Prod.mk.inj (Except.ok.inj ((enumMap_list_pure oldEvents _).symm.trans mapped))).1.symm
    subst mappedEvents
    obtain ⟨keptEvents, _, filteredEvents, h⟩ := bind_ok h
    have subsetEvents := (filterM_sublist filteredEvents).subset
    obtain ⟨results, _, readResults, h⟩ := bind_ok h
    have same := (field_value readResults).trans resultsRead
    subst results
    obtain ⟨mappedResults, _, mapped, h⟩ := bind_ok h
    change enumMap (list oldResults) pure _ = _ at mapped
    have same := (Prod.mk.inj (Except.ok.inj ((enumMap_list_pure oldResults _).symm.trans mapped))).1.symm
    subst mappedResults
    obtain ⟨keptResults, _, filteredResults, h⟩ := bind_ok h
    have subsetResults := (filterM_sublist filteredResults).subset
    obtain ⟨advanced, _, written, h⟩ := bind_ok h
    have advancedNumbers : AuxiliaryNumbers advanced := by
      refine ⟨⟨keptEvents, write_get_key "events" written rfl, ?_⟩,
        ⟨keptResults, write_get_key "async_results" written rfl, ?_⟩⟩
      · exact fun event member => eventNumbers event (subsetEvents member)
      · exact fun result member => resultNumbers result (subsetResults member)
    obtain ⟨pruned, _, prunedCall, h⟩ := bind_ok h
    exact (recomputeContext_auxiliary_frame h).numbers
      ((pruneResultRefs_auxiliary_frame prunedCall).numbers advancedNumbers)

end VerifiedKernel.Session.WorkConservation
