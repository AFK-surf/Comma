import VerifiedKernelProofs.Session.WorkHistoryNumbers

namespace VerifiedKernel.Session.WorkConservation
open Data ReloadSequence
set_option Elab.async false
set_option maxHeartbeats 4000000

theorem capabilitySync_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : capabilitySync s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold capabilitySync at h
  auxiliary_frame_walk h

theorem conversationSourceAdvance_auxiliary_frame {s e t : Term} {j r : List Term}
    (h : conversationSourceAdvance s e j = .ok (t, r)) : AuxiliaryFrame s t := by
  unfold conversationSourceAdvance at h
  auxiliary_frame_walk h

theorem inner_auxiliary_numbers {s e t : Term} {j r : List Term}
    (h : inner s e j = .ok (t, r)) : AuxiliaryStep s t := by
  intro sorted numbers
  unfold inner at h
  simp only [ite_ok_iff] at h
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (progressStep_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (asyncStart_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact asyncTerminal_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact asyncTerminal_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact asyncTerminal_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (capabilitySync_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (statusTransition_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (activityTransition_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (metadataCreated_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (conversationSourceAdvance_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (write_auxiliary_frame h rfl rfl).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (metadataPrompt_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (metadataUpdate_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (compactionFailure_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact compactionRecovery_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (queueAppend_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (queueAck_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (queueConsume_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact replyRepair_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (replyIntent_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (retireIntent_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (activationStarted_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (activationFinished_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (obligationResolve_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (obligationCard_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (sessionAck_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    exact (write_auxiliary_frame h rfl rfl).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (waitClear_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptToolResult_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptAssistant_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptLog_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptSeed_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptRuntime_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (transcriptDelivery_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact sessionEvent_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (microcompact_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (historyCompaction_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (historyCompaction_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact compactResult_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact archiveAdvance_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact storedResult_auxiliary_numbers h sorted numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (sessionStamp_auxiliary_frame h).numbers numbers
  obtain ⟨_, h⟩ | ⟨_, h⟩ := h
  · exact (bumpHwmEvent_auxiliary_frame h).numbers numbers
  rw [pure_ok h]
  exact numbers

theorem inner_history_numbers {s e t : Term} {j r : List Term}
    (h : inner s e j = .ok (t, r)) (sorted : SeqSorted s) (numbers : HistoryNumbers s) :
    SeqSorted t ∧ HistoryNumbers t := by
  have nextSorted := inner_seq h sorted
  exact ⟨nextSorted, history_numbers_from_auxiliary nextSorted
    (inner_auxiliary_numbers h sorted ⟨numbers.2.1, numbers.2.2.1⟩)⟩

theorem activity_frame_history_numbers {s t : Term} (frame : ActivityFrame s t)
    (sorted : SeqSorted s) (numbers : HistoryNumbers s) : SeqSorted t ∧ HistoryNumbers t := by
  have nextSorted := activity_frame_seq frame sorted
  have aux : AuxiliaryFrame s t := ⟨frame _ (by decide) (by decide), frame _ (by decide) (by decide)⟩
  exact ⟨nextSorted, history_numbers_from_auxiliary nextSorted
    (aux.numbers ⟨numbers.2.1, numbers.2.2.1⟩)⟩

theorem resident_step_history_numbers {s e t : Term} (step : ResidentStep s e t)
    (sorted : SeqSorted s) (numbers : HistoryNumbers s) : SeqSorted t ∧ HistoryNumbers t := by
  obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := step
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activity
    exact activity_frame_history_numbers activity sorted numbers
  | some normalized =>
    obtain ⟨_, _, _, call⟩ := prepareTrusted_stringify prepared
    obtain ⟨nextSorted, nextNumbers⟩ := inner_history_numbers call sorted numbers
    exact activity_frame_history_numbers activity nextSorted nextNumbers

theorem resident_batch_history_numbers {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t) (sorted : SeqSorted s) (numbers : HistoryNumbers s) :
    SeqSorted t ∧ HistoryNumbers t := by
  induction execution with
  | nil => exact ⟨sorted, numbers⟩
  | cons first rest ih =>
    obtain ⟨nextSorted, nextNumbers⟩ :=
      resident_step_history_numbers (resident_execution_step first) sorted numbers
    exact ih nextSorted nextNumbers

theorem persistable_history_numbers {s t : Term} {j r : List Term}
    (h : Lifecycle.persistable s j = .ok (t, r))
    (sorted : SeqSorted s) (numbers : HistoryNumbers s) : SeqSorted t ∧ HistoryNumbers t := by
  have frame : AuxiliaryFrame s t := by
    rw [put_ok h]
    exact ⟨get_put_other _ _ (by decide), get_put_other _ _ (by decide)⟩
  have nextSorted : SeqSorted t := by
    apply seq_of_frame (s := s) ?_ ?_ sorted
    all_goals rw [put_ok h]; exact get_put_other _ _ (by decide)
  exact ⟨nextSorted, history_numbers_from_auxiliary nextSorted
    (frame.numbers ⟨numbers.2.1, numbers.2.2.1⟩)⟩

theorem prepareWrite_history_numbers {s result : Term} {format : Int} {j r : List Term}
    (stored : s.get (a "storage_format") = i format) (modern : format = 2 ∨ format = 3)
    (sorted : SeqSorted s) (numbers : HistoryNumbers s)
    (h : Lifecycle.prepareWrite s j = .ok (result, r)) :
    ∃ t, result = .tuple [a "ok", t] ∧ SeqSorted t ∧ HistoryNumbers t := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  obtain ⟨nextSorted, nextNumbers⟩ := normalize_sequence numbers sorted normalizedRead
  have formatRead := normalize_format stored normalizedRead
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have same := (field_value valueRead).trans formatRead
  subst value
  have notLegacy : (i format == i 1) = false := by rcases modern with rfl | rfl <;> rfl
  have supported : (i format == i 2 || i format == i 3) = true := by rcases modern with rfl | rfl <;> rfl
  simp only [notLegacy, Bool.false_eq_true, supported, ↓reduceIte] at h
  obtain ⟨t, _, written, h⟩ := bind_ok h
  have sorted' := write_seq_frame written rfl nextSorted
  exact ⟨t, pure_ok h, sorted', history_numbers_from_auxiliary sorted'
    ((write_auxiliary_frame written rfl rfl).numbers ⟨nextNumbers.2.1, nextNumbers.2.2.1⟩)⟩

theorem persist_load_history_numbers {s snapshot decodedState loaded : Term} {bytes : ByteArray}
    {resident : Option Term} {rest : List Term}
    (ready : QueueReady s) (sorted : SeqSorted s) (numbers : HistoryNumbers s)
    (persisted : Lifecycle.persistable s [] = .ok (snapshot, rest))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (reload : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    SeqSorted loaded ∧ HistoryNumbers loaded := by
  obtain ⟨snapshotSorted, snapshotNumbers⟩ := persistable_history_numbers persisted sorted numbers
  exact load_trace_sequence decoded (codec.ready (persistable_preserves ready persisted).1)
    (codec_history_numbers codec snapshotNumbers) (codec.seqSorted snapshotSorted) reload

inductive HistoryReachable : Term → Prop where
  | create {s args t : Term} {j r : List Term}
      (created : Lifecycle.create s args j = .ok (t, r)) : HistoryReachable t
  | batch {s t : Term} {events : List Term} (before : HistoryReachable s)
      (execution : ResidentBatch s events t) : HistoryReachable t
  | prepare {s t : Term} {j r : List Term} {format : Int} (before : HistoryReachable s)
      (stored : s.get (a "storage_format") = i format) (modern : format = 2 ∨ format = 3)
      (prepared : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", t], r)) : HistoryReachable t
  | reload {s snapshot decodedState loaded : Term} {bytes : ByteArray}
      {resident : Option Term} {rest : List Term} (before : HistoryReachable s)
      (ready : QueueReady s)
      (persisted : Lifecycle.persistable s [] = .ok (snapshot, rest))
      (exported : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
        (some s, .tuple [i 1, a "ok", .binary bytes]))
      (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
      (codec : ValueSemantics.Equivalent snapshot decodedState)
      (reload : ReloadTrace
        (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
        (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]])) : HistoryReachable loaded

theorem HistoryReachable.sequence {state : Term} (reachable : HistoryReachable state) :
    SeqSorted state ∧ HistoryNumbers state := by
  induction reachable with
  | create created => exact ⟨create_sequence_invariant created, create_history_numbers created⟩
  | batch before execution ih => exact resident_batch_history_numbers execution ih.1 ih.2
  | prepare before stored modern prepared ih =>
    obtain ⟨next, same, sorted, numbers⟩ := prepareWrite_history_numbers stored modern ih.1 ih.2 prepared
    have equal := same
    simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at equal
    cases equal
    exact ⟨sorted, numbers⟩
  | reload before ready persisted exported decoded codec reload ih =>
    exact persist_load_history_numbers ready ih.1 ih.2 persisted decoded codec reload

end VerifiedKernel.Session.WorkConservation
