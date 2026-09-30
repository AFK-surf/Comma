import VerifiedKernelProofs.Session.WorkArchivePersistence

namespace VerifiedKernel.Session.StorageCommit
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem start_capture {state args cursor request : Term}
    (h : resident (some state) (a "start") args = (some cursor, request)) :
    cursor = .tuple [a "storage_commit_pending", state] ∧ prepare state args [] = .ok (request, []) := by
  simp only [resident, a] at h
  split at h
  · rename_i issued prepared
    cases h
    exact ⟨rfl, prepared⟩
  · have impossible := congrArg Prod.fst h
    cases impossible
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem resume_capture {state result restored etag : Term}
    (h : resident (some (.tuple [a "storage_commit_pending", state])) (a "resume") result =
      (some restored, .tuple [a "ok", etag])) :
    restored = state ∧ ∃ outcome, result = .tuple [a "ok", etag, outcome] := by
  simp only [resident, a] at h
  split at h
  · rename_i response finished
    have pair := Prod.mk.inj h
    have same := Option.some.inj pair.1
    refine ⟨same.symm, ?_⟩
    rw [pair.2] at finished
    exact storage_commit_confirmation finished
  · have impossible := congrArg Prod.fst h
    cases impossible

/-- The actual resident start/resume pair binds a positive result to one candidate, request, and revision. -/
theorem confirmed_candidate {state key base cursor request result restored etag : Term} {durable : HotSnapshots}
    (started : resident (some state) (a "start") (.tuple [key, base]) = (some cursor, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : resident (some cursor) (a "resume") result = (some restored, .tuple [a "ok", etag])) :
    restored = state ∧ ∃ snapshot bytes,
      Lifecycle.persistable state [] = .ok (snapshot, []) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, base] ∧ durable key etag snapshot := by
  obtain ⟨cursorEq, prepared⟩ := start_capture started
  rw [cursorEq] at resumed
  obtain ⟨restoredEq, outcome, resultEq⟩ := resume_capture resumed
  obtain ⟨snapshot, bytes, rest, persisted, encoded, requestEq, _⟩ := storage_commit_candidate prepared
  have clean : Lifecycle.persistable state [] = .ok (snapshot, []) := by
    have shape := put_ok persisted
    unfold Lifecycle.persistable Data.put at persisted ⊢
    split at persisted
    · rename_i map
      simp only [map, ↓reduceIte]
      rw [shape]
      rfl
    · exact (fail_ok persisted).elim
  exact ⟨restoredEq, snapshot, bytes, clean, encoded, requestEq,
    primitive key base bytes snapshot etag outcome requestEq encoded resultEq⟩

end VerifiedKernel.Session.StorageCommit
