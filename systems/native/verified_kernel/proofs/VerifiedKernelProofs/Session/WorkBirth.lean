import VerifiedKernelProofs.Session.WorkCapturedRevision

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

/-- Native calls used by creation and seed-before-live, before the create-only CAS. -/
inductive Birth (captured : List CapturedRevision) : ByteArray → ByteArray → Term → Prop where
  | create {owner session : ByteArray} {state attrs next : Term} {journal rest : List Term}
      (call : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (next, rest)) :
      Birth captured owner session next
  | fork {source : CapturedRevision} {session : ByteArray} {attrs next : Term} {journal rest : List Term}
      (member : source ∈ captured)
      (call : Fork.fork source.cursor.candidate.working (.tuple [.binary session, attrs]) journal =
        .ok (.tuple [a "ok", next], rest)) : Birth captured source.owner session next
  | clone {source : CapturedRevision} {owner session : ByteArray} {attrs fresh next : Term} {journal rest : List Term}
      (member : source ∈ captured)
      (call : Fork.fork source.cursor.candidate.working (.tuple [.binary session, attrs]) journal =
        .ok (.tuple [a "ok", fresh], rest))
      (stamp : ResidentBatch fresh [cloneOwnerEvent owner] next) : Birth captured owner session next
  | prepare {owner session : ByteArray} {state next : Term} {journal rest : List Term}
      (before : Birth captured owner session state)
      (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
      Birth captured owner session next
  | metadata {owner session : ByteArray} {state next : Term} {events : List Term}
      (before : Birth captured owner session state)
      (call : ResidentBatch state events next)
      (canonical : ∀ event ∈ events, BinaryKeys event)
      (kinds : ∀ event ∈ events, CommitMetadata event) : Birth captured owner session next

theorem Birth.physical {framing : CodecFraming} {objects : Objects} {versions : VersionBytes}
    {captured : List CapturedRevision} {owner session : ByteArray} {state : Term}
    (valid : ∀ source ∈ captured, source.Valid framing objects versions)
    (birth : Birth captured owner session state) : PhysicalHistory framing objects owner session state [] := by
  induction birth with
  | create call => exact .create call
  | fork member call =>
    obtain ⟨sealed, history⟩ := (valid _ member).1
    exact history.fork call
  | clone member call stamp =>
    obtain ⟨sealed, history⟩ := (valid _ member).1
    exact history.clone call stamp
  | prepare before call ih => exact ih.prepare call
  | metadata before call canonical kinds ih => exact ih.metadata call canonical kinds

end VerifiedKernel.Session.WorkConservation.CurrentExecution
