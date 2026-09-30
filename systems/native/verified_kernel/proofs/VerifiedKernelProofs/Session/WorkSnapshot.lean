import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernel.Dispatch
import VerifiedKernelProofs.Session.WorkPersistence

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem persist_dispatch_snapshot {s : Term} {bytes : ByteArray}
    (h : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some s, .tuple [i 1, a "ok", .binary bytes])) :
    ∃ snapshot rest, Lifecycle.persistable s [] = .ok (snapshot, rest) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes := by
  change (match Lifecycle.persistable s [] with
    | .ok (snapshot, _) =>
      match ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) with
      | .ok encoded => (some s, Term.tuple [i 1, a "ok", .binary encoded])
      | .error code => (none, Term.tuple [i 1, a "error", a "wire", b code])
    | .error _ => (none, Term.tuple [i 1, a "error", a "session", b "persist_failed"])) =
      (some s, .tuple [i 1, a "ok", .binary bytes]) at h
  split at h
  · rename_i snapshot rest persisted
    split at h
    · rename_i encoded encodedRead
      have response := (Prod.mk.inj h).2
      change Term.tuple [i 1, a "ok", .binary encoded] = .tuple [i 1, a "ok", .binary bytes] at response
      have same : encoded = bytes := by simpa only [Prod.mk.injEq, Term.tuple.injEq,
        List.cons.injEq, Term.binary.injEq, and_true, true_and] using response
      subst encoded
      exact ⟨snapshot, rest, persisted, encodedRead⟩
    · cases (Prod.mk.inj h).1
  · cases (Prod.mk.inj h).1

theorem persist_dispatch_preserves {s : Term} {bytes : ByteArray}
    (ready : QueueReady s)
    (h : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some s, .tuple [i 1, a "ok", .binary bytes])) :
    ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      QueueReady snapshot ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented snapshot sealed item := by
  obtain ⟨snapshot, rest, persisted, encoded⟩ := persist_dispatch_snapshot h
  exact ⟨snapshot, encoded, persistable_preserves ready persisted⟩

end VerifiedKernel.Session.WorkConservation
