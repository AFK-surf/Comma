import VerifiedKernelProofs.Session.WorkForkHistory

namespace VerifiedKernel.Session.WorkConservation
open Data ReloadSequence
set_option Elab.async false

structure KernelInvariant (state : Term) (sealed : List Term) : Prop where
  ready : QueueReady state
  format : state.get (a "storage_format") = i 3
  header : LedgerHeader state
  supported : LedgerSupported state sealed
  sorted : SeqSorted state
  numbers : HistoryNumbers state

inductive KernelHistory : Term → List Term → Prop where
  | create {state args next : Term} {journal rest : List Term}
      (call : Lifecycle.create state args journal = .ok (next, rest)) : KernelHistory next []
  | fork {source args next : Term} {journal rest : List Term}
      (format : source.get (a "storage_format") = i 3)
      (call : Fork.fork source args journal = .ok (.tuple [a "ok", next], rest)) : KernelHistory next []
  | nonretiring {state next : Term} {events sealed : List Term}
      (before : KernelHistory state sealed) (execution : ResidentBatch state events next)
      (canonical : ∀ event ∈ events, BinaryKeys event)
      (safe : ∀ event ∈ events, NonRetiring event) : KernelHistory next sealed
  | reduceOrdinary {state event next : Term} {sealed journal rest : List Term}
      (before : KernelHistory state sealed) (safe : NonRetiring event)
      (call : Session.inner state event journal = .ok (next, rest)) : KernelHistory next sealed
  | materialize {state next : Term} {events sealed journal rest : List Term} {limit : Int} {wake : Bool} {hwm : Term}
      (before : KernelHistory state sealed)
      (planned : StateQuery.materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
      (execution : ResidentBatch state events next) : KernelHistory next sealed
  | normalize {state next : Term} {sealed journal rest : List Term}
      (before : KernelHistory state sealed)
      (call : Lifecycle.normalize state journal = .ok (next, rest)) : KernelHistory next sealed
  | materialize_framed {state projected next : Term} {events sealed journal rest : List Term}
      {limit : Int} {wake : Bool} {hwm : Term}
      (before : KernelHistory state sealed)
      (queue : projected.get (a "input_queue") = state.get (a "input_queue"))
      (ack : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
      (session : state.get (a "session_id") = projected.get (a "session_id"))
      (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
      (execution : ResidentBatch state events next) : KernelHistory next sealed
  | prepare {state next : Term} {sealed journal rest : List Term}
      (before : KernelHistory state sealed)
      (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) : KernelHistory next sealed
  | persist {state next : Term} {sealed journal rest : List Term}
      (before : KernelHistory state sealed)
      (call : Lifecycle.persistable state journal = .ok (next, rest)) : KernelHistory next sealed
  | reload {state decodedState next : Term} {resident : Option Term} {sealed : List Term} {bytes : ByteArray}
      (before : KernelHistory state sealed)
      (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
      (codec : ValueSemantics.Equivalent state decodedState)
      (trace : ReloadTrace
        (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
        (some next, .tuple [i 1, a "ok", .tuple [a "done"]])) : KernelHistory next sealed
  | decode {state next : Term} {sealed : List Term} {bytes : ByteArray}
      (before : KernelHistory state sealed)
      (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, next]))
      (codec : ValueSemantics.Equivalent state next) : KernelHistory next sealed
  | activity {state next : Term} {sealed : List Term}
      (before : KernelHistory state sealed) (frame : ActivityFrame state next) : KernelHistory next sealed
  | archive {state event next : Term} {live dropped kept sealed journal rest : List Term}
      (before : KernelHistory state sealed) (kind : event.get (b "type") = b "archive_advance")
      (call : archiveAdvance state event journal = .ok (next, rest))
      (read : state.get (a "messages") = list live) (partition : live = dropped ++ kept)
      (after : next.get (a "messages") = list kept) : KernelHistory next (sealed ++ dropped)

theorem KernelHistory.invariant {state : Term} {sealed : List Term} (history : KernelHistory state sealed) :
    KernelInvariant state sealed := by
  induction history with
  | create call =>
    exact ⟨create_ready call, create_format call, create_ledger_header call, create_ledger_supported call,
      create_sequence_invariant call, create_history_numbers call⟩
  | fork format call =>
    have initial := modern_fork_initial format call
    have sequence := modern_fork_history format call
    exact ⟨initial.ready, initial.format, initial.header, modern_fork_ledger_supported format call, sequence.1, sequence.2⟩
  | nonretiring before execution canonical safe ih =>
    have kept := nonretiring_batch_preserves execution ih.ready ih.format canonical safe
    have sequence := resident_batch_history_numbers execution ih.sorted ih.numbers
    exact ⟨kept.1, kept.2.1, batch_ledger_header execution ih.header,
      nonretiring_batch_ledger_supported execution ih.ready ih.format canonical safe ih.supported, sequence.1, sequence.2⟩
  | reduceOrdinary before safe call ih =>
    have sequence := inner_history_numbers call ih.sorted ih.numbers
    exact ⟨nonretiring_inner_ready ih.ready safe call, (inner_format call).trans ih.format,
      inner_ledger_header ih.header call,
      nonretiring_inner_ledger_supported ih.ready ih.format safe ih.supported call, sequence.1, sequence.2⟩
  | materialize before planned execution ih =>
    have sequence := resident_batch_history_numbers execution ih.sorted ih.numbers
    exact ⟨materialize_resident_ready ih.ready planned execution,
      (resident_batch_format execution).trans ih.format, batch_ledger_header execution ih.header,
      materialize_ledger_supported ih.ready ih.supported planned execution, sequence.1, sequence.2⟩
  | normalize before call ih =>
    have sequence := normalize_sequence ih.numbers ih.sorted call
    exact ⟨(normalize_work ih.ready call).1, normalize_format ih.format call, normalize_ledger_header call,
      normalize_ledger_supported ih.ready ih.header ih.supported call, sequence.1, sequence.2⟩
  | materialize_framed before queue ack session planned execution ih =>
    have sequence := resident_batch_history_numbers execution ih.sorted ih.numbers
    exact ⟨(materialize_framed_work ih.ready queue ack session planned execution).1,
      (resident_batch_format execution).trans ih.format, batch_ledger_header execution ih.header,
      materialize_framed_ledger_supported ih.ready queue ack session planned execution ih.supported,
      sequence.1, sequence.2⟩
  | @prepare state next sealed journal rest before call ih =>
    obtain ⟨normalized, same, format, ready, _⟩ := prepareWrite_modern ih.format (Or.inr rfl) ih.ready call
    have equal : next = normalized := by
      simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
    subst normalized
    obtain ⟨numbered, same, sorted, numbers⟩ := prepareWrite_history_numbers ih.format (Or.inr rfl) ih.sorted ih.numbers call
    have equal : next = numbered := by
      simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
    subst numbered
    have ledger := prepare_write_ledger_supported ih.ready ih.format ih.header ih.supported call
    exact ⟨ready, format, ledger.2, ledger.1, sorted, numbers⟩
  | persist before call ih =>
    have sequence := persistable_history_numbers call ih.sorted ih.numbers
    exact ⟨(persistable_preserves ih.ready call).1, (persistable_queue_frame call).2.2.2.2.trans ih.format,
      persistable_ledger_header ih.header call, persistable_ledger_supported ih.supported call, sequence.1, sequence.2⟩
  | reload before decoded codec trace ih =>
    have ready := codec.ready ih.ready
    have header := equivalent_ledger_header ih.header codec
    have support := equivalent_ledger_supported codec ih.supported
    have format := codec.get (a "storage_format")
    rw [ih.format] at format
    obtain ⟨journal, rest, normalized⟩ := load_trace_normalizes decoded ready trace
    have sequence := normalize_sequence (codec_history_numbers codec ih.numbers) (codec.seqSorted ih.sorted) normalized
    exact ⟨(normalize_work ready normalized).1, normalize_format format.integer normalized,
      normalize_ledger_header normalized, normalize_ledger_supported ready header support normalized, sequence.1, sequence.2⟩
  | decode before decoded codec ih =>
    have format := codec.get (a "storage_format")
    rw [ih.format] at format
    exact ⟨codec.ready ih.ready, format.integer, equivalent_ledger_header ih.header codec,
      equivalent_ledger_supported codec ih.supported, codec.seqSorted ih.sorted, codec_history_numbers codec ih.numbers⟩
  | @activity state next sealed before frame ih =>
    have sequence := activity_frame_history_numbers frame ih.sorted ih.numbers
    have header : LedgerHeader next := by
      unfold LedgerHeader
      rw [frame "input_dedupe" (by decide) (by decide)]
      exact ih.header
    exact ⟨queue_frame_ready (activity_frame_queue frame) ih.ready,
      (frame "storage_format" (by decide) (by decide)).trans ih.format, header,
      activity_ledger_supported frame ih.supported, sequence.1, sequence.2⟩
  | @archive state event next live dropped kept sealed journal rest before kind call read partition after ih =>
    have actual : inner state event journal = .ok (next, rest) := by simpa +decide [inner, kind] using call
    have sequence := inner_history_numbers actual ih.sorted ih.numbers
    have frame := archiveAdvance_queue_frame call
    exact ⟨queue_frame_ready frame ih.ready, frame.2.2.2.2.trans ih.format,
      inner_ledger_header ih.header actual, archive_ledger_supported read partition after ih.supported call, sequence.1, sequence.2⟩

theorem KernelHistory.identity_supported {state : Term} {sealed : List Term} {source : ByteArray}
    (history : KernelHistory state sealed)
    (present : IdentityPresent (state.get (a "input_dedupe")) (.binary source)) : IdentitySupported state sealed source :=
  history.invariant.supported source present

end VerifiedKernel.Session.WorkConservation
