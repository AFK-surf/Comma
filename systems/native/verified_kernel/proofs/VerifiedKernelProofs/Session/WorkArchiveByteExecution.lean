import VerifiedKernelProofs.Session.WorkByteResidentExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

inductive ArchiveByteStep : ByteStore → Term → Term → ByteStore → Prop where
  | read {store : ByteStore} {agent session first value : Term} {bytes : ByteArray}
      (stored : store (key agent session first) = some bytes)
      (decoded : ETF.decode bytes = .ok value) :
      ArchiveByteStep store (.tuple [a "read_segment", agent, session, first])
        (.tuple [a "ok", value]) store
  | missing {store : ByteStore} {agent session first : Term}
      (absent : store (key agent session first) = none) :
      ArchiveByteStep store (.tuple [a "read_segment", agent, session, first])
        (.tuple [a "error", a "not_found"]) store
  | create {store : ByteStore} {agent session first : Term} {bytes : ByteArray}
      (absent : store (key agent session first) = none) :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (a "created") (insertArchiveBytes store (key agent session first) bytes)
  | landed {store : ByteStore} {agent session first : Term} {bytes : ByteArray}
      (absent : store (key agent session first) = none) :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (a "landed") (insertArchiveBytes store (key agent session first) bytes)
  | landedError {store : ByteStore} {agent session first reason : Term} {bytes : ByteArray}
      (absent : store (key agent session first) = none) :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (.tuple [a "error", reason]) (insertArchiveBytes store (key agent session first) bytes)
  | landedExisting {store : ByteStore} {agent session first : Term} {bytes : ByteArray}
      (stored : store (key agent session first) = some bytes) :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (a "landed") store
  | exists {store : ByteStore} {agent session first value : Term} {requested bytes : ByteArray}
      (stored : store (key agent session first) = some bytes)
      (decoded : ETF.decode bytes = .ok value) :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary requested])
        (.tuple [a "exists", value]) store
  | readError {store : ByteStore} {agent session first reason : Term} :
      ArchiveByteStep store (.tuple [a "read_segment", agent, session, first])
        (.tuple [a "error", reason]) store
  | createError {store : ByteStore} {agent session first reason : Term} {bytes : ByteArray} :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (.tuple [a "error", reason]) store
  | invalidRead {store : ByteStore} {agent session first : Term} :
      ArchiveByteStep store (.tuple [a "read_segment", agent, session, first]) (a "invalid_segment") store
  | invalidExisting {store : ByteStore} {agent session first : Term} {bytes : ByteArray} :
      ArchiveByteStep store (.tuple [a "create_segment", agent, session, first, .binary bytes])
        (a "invalid_segment") store
  | codec {store : ByteStore} {left right result : Term}
      (meaning : CodecMeaning (.tuple [a "request_batch", list [
        .tuple [a "deterministic_etf", left], .tuple [a "deterministic_etf", right]]]) result) :
      ArchiveByteStep store (.tuple [a "request_batch", list [
        .tuple [a "deterministic_etf", left], .tuple [a "deterministic_etf", right]]]) result store

theorem ArchiveByteStep.extension {before after : ByteStore} {request result : Term}
    (step : ArchiveByteStep before request result after) : before.Extends after := by
  cases step with
  | create absent => exact byte_insert_extends absent
  | landed absent => exact byte_insert_extends absent
  | landedError absent => exact byte_insert_extends absent
  | _ => exact fun _ _ h => h

theorem ArchiveByteStep.observations {before after : ByteStore} {request result : Term}
    (step : ArchiveByteStep before request result after) : ByteObservations after request result := by
  cases step
  all_goals simp +decide [ByteObservations, a, list, insertArchiveBytes]
  all_goals intros
  all_goals subst_vars
  all_goals first
    | assumption
    | exact ⟨_, by assumption, by assumption⟩
    | simp

theorem ArchiveByteStep.codec_meaning {before after : ByteStore} {request result : Term}
    (step : ArchiveByteStep before request result after) : CodecMeaning request result := by
  cases step
  all_goals first
    | assumption
    | simp +decide [CodecMeaning, a, list]

theorem ArchiveByteStep.primitive {before after : ByteStore} {request result : Term}
    (roundtrip : ∀ value bytes, ETF.encode value = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok decoded ∧ ValueSemantics.Equivalent value decoded)
    (step : ArchiveByteStep before request result after) :
    PrimitiveStep before.objects after.objects request result :=
  byte_observations_refine step.extension step.observations roundtrip step.codec_meaning

theorem ArchiveByteStep.resident {versions : VersionBytes} {world : ByteResidentWorld}
    {after : ByteStore} {request result : Term}
    (step : ArchiveByteStep world.archive request result after) :
    ByteResidentStep versions world { world with archive := after } := by
  cases step with
  | create absent => exact .create absent
  | landed absent => exact .create absent
  | landedError absent => exact .create absent
  | _ => exact .hot rfl (.unchanged _)

end VerifiedKernel.Session.WorkConservation.CurrentExecution
