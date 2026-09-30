import VerifiedKernelProofs.Session.WorkPersistence

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem overrides_get {s : Term} {entries : List (String × Term)} {key : String}
    (absent : entries.all (fun pair => pair.1 != key) = true) :
    (entries.foldl (fun state pair => state.put (a pair.1) pair.2) s).get (a key) = s.get (a key) := by
  induction entries generalizing s with
  | nil => rfl
  | cons pair entries ih =>
    simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne] at absent
    rw [List.foldl_cons, ih absent.2, get_put_other _ _ absent.1]

theorem create_format {s args t : Term} {j r : List Term}
    (h : Lifecycle.create s args j = .ok (t, r)) : t.get (a "storage_format") = i 3 := by
  unfold Lifecycle.create at h
  split at h
  · repeat
      fail_if_success (head_is h [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (t, r) at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    apply normalize_format (format := 3) (h := h)
    unfold Lifecycle.build
    iterate 3 rw [List.foldl_cons]
    rw [overrides_get (by rfl)]
    exact get_put_same _ _ _
  · exact (fail_ok h).elim

theorem create_work_invariant {s args t : Term} {j r : List Term}
    (h : Lifecycle.create s args j = .ok (t, r)) : QueueReady t ∧ t.get (a "storage_format") = i 3 :=
  ⟨create_ready h, create_format h⟩

end VerifiedKernel.Session.WorkConservation
