import VerifiedKernel.AgentLoop.Dispatch
import VerifiedKernel.Term
import VerifiedKernelProofs.AgentLoop.Round
import VerifiedKernelProofs.AgentLoop.Dependency
import VerifiedKernelProofs.AgentLoop.Policy

namespace VerifiedKernel.AgentLoop

theorem terminal_owner_iff (os oc s c : Identity) :
    terminalOwner os oc s c = true ↔ os = s ∧ oc = c := by simp [terminalOwner]

theorem accepted_pair_unique (os oc s c s' c' : Identity)
    (h : terminalOwner os oc s c = true) (h' : terminalOwner os oc s' c' = true) :
    s = s' ∧ c = c' := by
  simp only [terminal_owner_iff] at h h'
  exact ⟨h.1.symm.trans h'.1, h.2.symm.trans h'.2⟩

end VerifiedKernel.AgentLoop
