import VerifiedKernelProofs.RequestPrefix.Stateless

/-!
Prefix stability of `Session.Presentation.sanitizeContext`.

The sanitizer maps `sanitizePublic` over the messages, and `sanitizePublic` reads only its own
message. Messages `B` that follow `A` therefore keep the sanitized `A` as a prefix.
-/

namespace VerifiedKernel.RequestPrefix
open Data Provider
open ProviderLoop (mapM_append_ok)

set_option maxHeartbeats 4000000

theorem sanitizePublic_stateless (m : Term) : Stateless (Session.Presentation.sanitizePublic m) := by
  stateless

/-- `sanitizeContext` keeps the output of `A` as a prefix when messages `B` follow. -/
theorem sanitize_append {A B : List Term} {out outA : Term} {j j' k k' : List Term}
    (h : Session.Presentation.sanitizeContext (A ++ B) j = .ok (out, k))
    (hA : Session.Presentation.sanitizeContext A j' = .ok (outA, k')) :
    ∃ xsA xsB, outA = list xsA ∧ out = list (xsA ++ xsB) := by
  unfold Session.Presentation.sanitizeContext at h hA
  obtain ⟨zs, j₁, hz, hp⟩ := Session.bind_ok_iff.mp h
  obtain ⟨zsA, j₂, hzA, hpA⟩ := Session.bind_ok_iff.mp hA
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at hp hpA
  obtain ⟨as, bs, j₃, ha, -, rfl⟩ := mapM_append_ok hz
  have same := Stateless.same (Stateless.mapM sanitizePublic_stateless A) ha hzA
  exact ⟨as, bs, by rw [hpA.1, same], hp.1⟩

end VerifiedKernel.RequestPrefix
