import VerifiedKernelProofs.Session.WorkForkInitial
import VerifiedKernelProofs.Session.WorkDurableReload

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem create_empty_archive_fields {state args next : Term} {journal rest : List Term}
    (call : Lifecycle.create state args journal = .ok (next, rest)) :
    next.get (a "segment_catalog") = list [] ∧ next.get (a "archived_through") = i 0 := by
  unfold Lifecycle.create at call
  split at call
  · repeat
      fail_if_success (head_is call [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (next, rest) at call)
      obtain ⟨_, _, _, call⟩ := bind_ok call
    exact normalize_archive_fields ((build_get rfl).trans rfl) ((build_get rfl).trans rfl) (by simp) call
  · exact (fail_ok call).elim

theorem create_initial_fields {state args next : Term} {journal rest : List Term}
    (call : Lifecycle.create state args journal = .ok (next, rest)) : InitialFields next := by
  obtain ⟨messages, last, read, _⟩ := create_sequence_invariant call
  have archive := create_empty_archive_fields call
  exact ⟨create_ready call, create_format call, create_ledger_header call, ⟨messages, read⟩, archive.1, archive.2⟩

theorem create_initial_identity {state args next : Term} {journal rest : List Term} (objects : Objects)
    (call : Lifecycle.create state args journal = .ok (next, rest)) :
    InitialFields next ∧ LedgerSupported next [] ∧ SealedImagesBacked objects next [] :=
  ⟨create_initial_fields call, create_ledger_supported call, by simp [SealedImagesBacked]⟩

theorem modern_fork_initial_identity {source args next : Term} {journal rest : List Term} (objects : Objects)
    (format : source.get (a "storage_format") = i 3)
    (call : Fork.fork source args journal = .ok (.tuple [a "ok", next], rest)) :
    InitialFields next ∧ LedgerSupported next [] ∧ SealedImagesBacked objects next [] ∧
      ∀ source, IdentityPresent (next.get (a "input_dedupe")) (.binary source) →
        PhysicalIdentitySupported objects next source := by
  have supported := modern_fork_ledger_supported (sealed := []) format call
  have backed : SealedImagesBacked objects next [] := by simp [SealedImagesBacked]
  exact ⟨modern_fork_initial format call, supported, backed,
    fun source present => identity_supported_physical backed (supported source present)⟩

end VerifiedKernel.Session.WorkConservation
