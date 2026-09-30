import VerifiedKernelProofs.Session.WorkPhysicalInvariant
import VerifiedKernelProofs.Session.WorkCloneScope

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

/-- Executable paths, with a projection that ignores only the two activity fields.
This does not model the current hot-object CAS world. -/
inductive PhysicalHistory (framing : CodecFraming) : Objects → ByteArray → ByteArray → Term → List Term → Prop where
  | create {objects : Objects} {owner session : ByteArray} {state attrs next : Term} {journal rest : List Term}
      (call : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (next, rest)) :
      PhysicalHistory framing objects owner session next []
  | fork {objects : Objects} {owner sourceSession session : ByteArray} {source attrs next : Term}
      {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects owner sourceSession source sealed)
      (call : Fork.fork source (.tuple [.binary session, attrs]) journal = .ok (.tuple [a "ok", next], rest)) :
      PhysicalHistory framing objects owner session next []
  | clone {objects : Objects} {oldOwner owner sourceSession session : ByteArray} {source attrs fresh next : Term}
      {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects oldOwner sourceSession source sealed)
      (call : Fork.fork source (.tuple [.binary session, attrs]) journal = .ok (.tuple [a "ok", fresh], rest))
      (stamped : ResidentBatch fresh [cloneOwnerEvent owner] next) :
      PhysicalHistory framing objects owner session next []
  | admitted {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed events : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
      (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) :
      PhysicalHistory framing objects owner session next sealed
  | nonretiring {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed events : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
      (safe : ∀ event ∈ events, NonRetiring event) (ownerFrame : OwnerFrame state next) :
      PhysicalHistory framing objects owner session next sealed
  | materialize {objects : Objects} {owner session : ByteArray} {state next : Term}
      {sealed events journal rest : List Term} {limit : Int} {wake : Bool} {hwm : Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (planned : StateQuery.materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
      (execution : ResidentBatch state events next) : PhysicalHistory framing objects owner session next sealed
  | reduceOrdinary {objects : Objects} {owner session : ByteArray} {state event next : Term}
      {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (safe : NonRetiring event) (ownerFrame : OwnerFrame state next)
      (call : inner state event journal = .ok (next, rest)) : PhysicalHistory framing objects owner session next sealed
  | metadata {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed events : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
      (metadata : ∀ event ∈ events, CommitMetadata event) : PhysicalHistory framing objects owner session next sealed
  | materialize_framed {objects : Objects} {owner session : ByteArray} {state projected next : Term}
      {sealed events journal rest : List Term} {limit : Int} {wake : Bool} {hwm : Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (queue : projected.get (a "input_queue") = state.get (a "input_queue"))
      (ack : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
      (sessionEq : state.get (a "session_id") = projected.get (a "session_id"))
      (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
      (execution : ResidentBatch state events next) : PhysicalHistory framing objects owner session next sealed
  | normalize {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (call : Lifecycle.normalize state journal = .ok (next, rest)) : PhysicalHistory framing objects owner session next sealed
  | prepare {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
      PhysicalHistory framing objects owner session next sealed
  | persist {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed journal rest : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (call : Lifecycle.persistable state journal = .ok (next, rest)) : PhysicalHistory framing objects owner session next sealed
  | reload {objects : Objects} {owner session bytes : ByteArray} {state decodedState next : Term}
      {resident : Option Term} {sealed : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
      (codec : ValueSemantics.Equivalent state decodedState)
      (trace : ReloadTrace
        (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
        (some next, .tuple [i 1, a "ok", .tuple [a "done"]])) : PhysicalHistory framing objects owner session next sealed
  | publication {objects nextObjects : Objects} {owner session : ByteArray} {state event next : Term}
      {sealed records live dropped kept journal rest : List Term} {ceiling line : Int} {final : Output}
      (before : PhysicalHistory framing objects owner session state sealed)
      (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
      (positive : line > 0) (execution : Execution (start state (i line)) objects final nextObjects)
      (emitted : final.2 = .tuple [a "advance", event])
      (reduced : archiveAdvance state event journal = .ok (next, rest))
      (read : state.get (a "messages") = list live) (partition : live = dropped ++ kept)
      (after : next.get (a "messages") = list kept) :
      PhysicalHistory framing nextObjects owner session next (sealed ++ dropped)
  | decode {objects : Objects} {owner session bytes : ByteArray} {state next : Term} {sealed : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, next]))
      (codec : ValueSemantics.Equivalent state next) : PhysicalHistory framing objects owner session next sealed
  | activity {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed : List Term}
      (before : PhysicalHistory framing objects owner session state sealed) (frame : ActivityFrame state next) :
      PhysicalHistory framing objects owner session next sealed
  | objects {objects nextObjects : Objects} {owner session : ByteArray} {state : Term} {sealed : List Term}
      (before : PhysicalHistory framing objects owner session state sealed)
      (extension : ObjectsExtend objects nextObjects) : PhysicalHistory framing nextObjects owner session state sealed

theorem PhysicalHistory.invariant {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {state : Term} {sealed : List Term} (history : PhysicalHistory framing objects owner session state sealed) :
    PhysicalInvariant objects owner session state sealed := by
  induction history with
  | create call => exact .create call
  | fork before call ih => exact ih.fork call
  | clone before call stamped ih =>
    exact (ih.fork call).clone_owner (modern_fork_initial ih.history.invariant.format call).catalog stamped
  | admitted before execution canonical allowed ih => exact ih.admitted execution canonical allowed
  | nonretiring before execution canonical safe ownerFrame ih => exact ih.nonretiring execution canonical safe ownerFrame
  | materialize before planned execution ih => exact ih.materialize planned execution
  | reduceOrdinary before safe ownerFrame call ih => exact ih.reduceOrdinary safe ownerFrame call
  | metadata before execution canonical metadata ih => exact ih.metadata execution canonical metadata
  | materialize_framed before queue ack sessionEq planned execution ih =>
    exact ih.materialize_framed queue ack sessionEq planned execution
  | normalize before call ih => exact ih.normalize call
  | prepare before call ih => exact ih.prepare call
  | persist before call ih => exact ih.persist call
  | reload before decoded codec trace ih => exact ih.reload decoded codec trace
  | decode before decoded codec ih => exact ih.decode decoded codec
  | activity before frame ih => exact ih.activity frame
  | publication before window positive execution emitted reduced read partition after ih =>
    exact ih.publication framing window positive execution emitted reduced read partition after
  | objects before extension ih => exact ih.objects extension

end VerifiedKernel.Session.WorkConservation
