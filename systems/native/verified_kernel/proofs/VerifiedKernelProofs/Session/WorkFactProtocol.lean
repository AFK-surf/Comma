import VerifiedKernelProofs.Session.WorkProtocol
import VerifiedKernelProofs.Session.WorkIdentityFacts

namespace VerifiedKernel.Session.WorkConservation.FactProtocol
open Data
set_option Elab.async false

/-- A fixed proof observer. Neither its identity nor its registry is stored at runtime. -/
structure Observer where
  key : Term
  fact : IdentityFact

def Observer.code (observer : Observer) : Term :=
  .tuple [observer.key, match observer.fact with
    | .work item => .tuple [a "work", item]
    | .record record => .tuple [a "record", record]]

theorem Observer.code_injective : Function.Injective Observer.code := by
  intro left right same
  cases left with
  | mk leftKey leftFact =>
    cases right with
    | mk rightKey rightFact =>
      cases leftFact <;> cases rightFact <;>
        simp_all [Observer.code, a]

structure State where
  registered : List Observer := []
  accepted : List Observer := []
  acknowledged : List Observer := []

def register (state : State) (observer : Observer) : State :=
  { state with registered := state.registered ++ [observer] }

def acknowledge (state : State) (observer : Observer) : State :=
  { state with acknowledged := state.acknowledged ++ [observer] }

def accept (state : State) (observer : Observer) : State :=
  { state with accepted := state.accepted ++ [observer] }

inductive Step : State → State → Prop where
  | register (state : State) (observer : Observer) : Step state (register state observer)
  | acknowledge (state : State) (observer : Observer) (ready : observer ∈ state.registered) :
      Step state (acknowledge state observer)
  | accept (state : State) (observer : Observer) (ready : observer ∈ state.registered) :
      Step state (accept state observer)

inductive Trace : State → State → Prop where
  | done (state : State) : Trace state state
  | next {before middle after : State} (step : Step before middle) (tail : Trace middle after) :
      Trace before after

theorem Trace.trans {before middle after : State} (first : Trace before middle) (last : Trace middle after) :
    Trace before after := by
  induction first with
  | done => exact last
  | next step tail ih => exact .next step (ih last)

theorem Trace.accepted_preserves {before after : State} (trace : Trace before after) :
    ∀ observer ∈ before.accepted, observer ∈ after.accepted := by
  induction trace with
  | done => exact fun _ h => h
  | next step tail ih =>
    intro observer member
    apply ih observer
    cases step with
    | register => exact member
    | acknowledge => exact member
    | accept => exact List.mem_append_left _ member

theorem Trace.acknowledged_preserves {before after : State} (trace : Trace before after) :
    ∀ observer ∈ before.acknowledged, observer ∈ after.acknowledged := by
  induction trace with
  | done => exact fun _ h => h
  | next step tail ih =>
    intro observer member
    apply ih observer
    cases step with
    | register => exact member
    | acknowledge => exact List.mem_append_left _ member
    | accept => exact member

def registerMany (state : State) : List Observer → State
  | [] => state
  | observer :: remaining => registerMany (register state observer) remaining

theorem registerMany_registered (state : State) (observers : List Observer) :
    (registerMany state observers).registered = state.registered ++ observers := by
  induction observers generalizing state with
  | nil => simp [registerMany]
  | cons observer remaining ih => simp [registerMany, ih, register, List.append_assoc]

theorem registerMany_trace (state : State) (observers : List Observer) :
    Trace state (registerMany state observers) := by
  induction observers generalizing state with
  | nil => exact .done _
  | cons observer remaining ih => exact .next (.register state observer) (ih _)

/-- This is a safety-subprotocol encoding, not a physical queue-location projection.
`queued` is an encoding slot for registered facts; no materialization transition is claimed here. -/
def State.protocol (state : State) (acceptances : Bool := false) : WorkConservation.Revision :=
  { durable := { queued := state.registered.map Observer.code }
    working := { queued := state.registered.map Observer.code }
    confirmable := state.registered.map Observer.code
    accepted := (if acceptances then state.accepted else state.acknowledged).map Observer.code }

inductive ProtocolTrace : WorkConservation.Revision → WorkConservation.Revision → Prop where
  | done (state : WorkConservation.Revision) : ProtocolTrace state state
  | next {before middle after : WorkConservation.Revision}
      (step : WorkConservation.Step before middle) (tail : ProtocolTrace middle after) :
      ProtocolTrace before after

theorem ProtocolTrace.trans {before middle after : WorkConservation.Revision}
    (first : ProtocolTrace before middle) (last : ProtocolTrace middle after) : ProtocolTrace before after := by
  induction first with
  | done => exact last
  | next step tail ih => exact .next step (ih last)

theorem Step.protocol {before after : State} (step : Step before after) (acceptances : Bool := false) :
    ProtocolTrace (before.protocol acceptances) (after.protocol acceptances) := by
  cases step with
  | register observer =>
    refine .next (.input (before.protocol acceptances) observer.code) (.next (.fence _) ?_)
    simpa [State.protocol, FactProtocol.register, List.map_append] using
      ProtocolTrace.done ((FactProtocol.register before observer).protocol acceptances)
  | acknowledge observer ready =>
    cases acceptances with
    | false =>
      refine .next (.notify before.protocol observer.code (List.mem_map.mpr ⟨observer, ready, rfl⟩)) ?_
      simpa [State.protocol, FactProtocol.acknowledge, List.map_append] using ProtocolTrace.done (FactProtocol.acknowledge before observer).protocol
    | true => exact .done _
  | accept observer ready =>
    cases acceptances with
    | false => exact .done _
    | true =>
      refine .next (.notify (before.protocol true) observer.code (List.mem_map.mpr ⟨observer, ready, rfl⟩)) ?_
      simpa [State.protocol, FactProtocol.accept, List.map_append] using
        ProtocolTrace.done ((FactProtocol.accept before observer).protocol true)

theorem Trace.protocol {before after : State} (trace : Trace before after) (acceptances : Bool := false) :
    ProtocolTrace (before.protocol acceptances) (after.protocol acceptances) := by
  induction trace with
  | done => exact .done _
  | next step tail ih => exact (step.protocol acceptances).trans ih

theorem ProtocolTrace.reachable {before after : WorkConservation.Revision}
    (prior : WorkConservation.Reachable before) (trace : ProtocolTrace before after) :
    WorkConservation.Reachable after := by
  induction trace with
  | done => exact prior
  | next step tail ih => exact ih (.next prior step)

theorem Trace.reachable {state : State} (trace : Trace {} state) (acceptances : Bool := false) :
    WorkConservation.Reachable (state.protocol acceptances) := by
  cases acceptances with
  | false => exact (trace.protocol false).reachable WorkConservation.Reachable.initial
  | true => exact (trace.protocol true).reachable WorkConservation.Reachable.initial

theorem acknowledged_registered {state : State} (trace : Trace {} state) {observer : Observer}
    (acknowledged : observer ∈ state.acknowledged) : observer ∈ state.registered := by
  have physical := accepted_work_conserved (trace.reachable false) observer.code (List.mem_map.mpr ⟨observer, acknowledged, rfl⟩)
  have registered : observer.code ∈ state.registered.map Observer.code := by
    simpa [State.protocol, Represented] using physical
  obtain ⟨original, member, same⟩ := List.mem_map.mp registered
  exact Observer.code_injective same ▸ member

theorem accepted_registered {state : State} (trace : Trace {} state) {observer : Observer}
    (accepted : observer ∈ state.accepted) : observer ∈ state.registered := by
  have physical := accepted_work_conserved (trace.reachable true) observer.code (List.mem_map.mpr ⟨observer, accepted, rfl⟩)
  have registered : observer.code ∈ state.registered.map Observer.code := by
    simpa [State.protocol, Represented] using physical
  obtain ⟨original, member, same⟩ := List.mem_map.mp registered
  exact Observer.code_injective same ▸ member

end VerifiedKernel.Session.WorkConservation.FactProtocol
