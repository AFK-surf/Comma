import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkOwner
import VerifiedKernelProofs.Session.WorkSemanticPipeline

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096
set_option Elab.async false

theorem normalize_owner {s t : Term} {j r : List Term}
    (owned : s.get (a "agent_id") ≠ nil)
    (h : Lifecycle.normalize s j = .ok (t, r)) : OwnerFrame s t := by
  have initial := fillDefaults_get (key := "agent_id") owned
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have selected : OwnerFrame s normalized := (owner_write written rfl).trans initial
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, providerWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact (owner_write h rfl).trans
    ((owner_write providerWrite rfl).trans ((owner_write activityWrite rfl).trans selected))

theorem prepareWrite_owner {s result : Term} {format : Int} {j r : List Term}
    (owned : s.get (a "agent_id") ≠ nil)
    (stored : s.get (a "storage_format") = i format) (modern : format = 2 ∨ format = 3)
    (h : Lifecycle.prepareWrite s j = .ok (result, r)) :
    ∃ t, result = .tuple [a "ok", t] ∧ OwnerFrame s t := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  have formatRead := normalize_format stored normalizedRead
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have same := (field_value valueRead).trans formatRead
  subst value
  have notLegacy : (i format == i 1) = false := by rcases modern with rfl | rfl <;> rfl
  have supported : (i format == i 2 || i format == i 3) = true := by rcases modern with rfl | rfl <;> rfl
  simp only [notLegacy, Bool.false_eq_true, supported, ↓reduceIte] at h
  obtain ⟨t, _, written, h⟩ := bind_ok h
  exact ⟨t, pure_ok h, (owner_write written rfl).trans (normalize_owner owned normalizedRead)⟩

theorem persistable_owner {s t : Term} {j r : List Term}
    (h : Lifecycle.persistable s j = .ok (t, r)) : OwnerFrame s t := by
  have same := put_ok h
  rw [same]
  exact get_put_other _ _ (by decide)

theorem load_trace_owner {resident : Option Term} {s t : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (ready : QueueReady s) (owned : s.get (a "agent_id") ≠ nil)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) : OwnerFrame s t := by
  have initial : ReloadEvidence s (SessionDomain.dispatch resident
      (.tuple [i 1, a "session", i 1, a "load", .binary bytes])) := by
    rw [load_dispatch_normalization decoded (queueReady_isMap ready)]
    exact normalizedResponse_evidence s [] ready
  obtain ⟨_, _, normalized⟩ := (reload_trace_evidence trace ready initial).1 t rfl
  exact normalize_owner owned normalized

/-- Semantic codec fidelity carries the Agent identity through actual persistence and reload. -/
theorem persist_load_owner {s snapshot decodedState loaded : Term} {bytes owner : ByteArray}
    {resident : Option Term} {rest : List Term}
    (ready : QueueReady s) (owned : s.get (a "agent_id") = .binary owner)
    (persisted : Lifecycle.persistable s [] = .ok (snapshot, rest))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (reload : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    loaded.get (a "agent_id") = .binary owner := by
  have snapshotOwner := (persistable_owner persisted).trans owned
  have field := codec.get (a "agent_id")
  rw [snapshotOwner] at field
  have decodedOwner := field.binary
  have nonnil : decodedState.get (a "agent_id") ≠ nil := by
    rw [decodedOwner]; intro impossible; cases impossible
  exact (load_trace_owner decoded (codec.ready (persistable_preserves ready persisted).1)
    nonnil reload).trans decodedOwner

end VerifiedKernel.Session.WorkConservation
