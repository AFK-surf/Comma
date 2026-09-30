import VerifiedKernelProofs.Session.WorkDriverFence

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

theorem fence_prepare_observation_resource {context : Context} {continuation key saved request : Term}
    {cursor : PendingRevision.Cursor} {observations : List Term}
    (h : acceptFence context continuation (RevisionFence.prepare cursor key observations) =
      (some saved, .tuple [a "observe", request])) :
    saved = fencingCursor context continuation
      (.tuple [a "session_fence_preparing", cursor.pack, key, list observations]) := by
  unfold RevisionFence.prepare at h
  split at h
  · simp [acceptFence, rejected, a] at h
  split at h
  · split at h <;> simp [acceptFence, RevisionFence.prepared, RevisionFence.invalid, a] at h
  · simp [acceptFence, rejected, a] at h
  · exact (Option.some.inj (congrArg Prod.fst h)).symm
  · simp [acceptFence, a] at h
  · simp [acceptFence, RevisionFence.invalid, a] at h

theorem fence_prepare_resume_captured (context : Context) (continuation key observation : Term)
    (cursor : PendingRevision.Cursor) (observations : List Term) :
    resident (some (fencingCursor context continuation
      (.tuple [a "session_fence_preparing", cursor.pack, key, list observations]))) (a "resume") observation =
      acceptFence context continuation (RevisionFence.prepare cursor key (observations ++ [observation])) := by
  rw [fence_resume_captured]
  rfl

theorem fence_preparation_observations_reflect {context : Context} {continuation key state : Term}
    {cursor : PendingRevision.Cursor} {observations : List Term}
    (trace : ObservationTrace
      (acceptFence context continuation (RevisionFence.prepare cursor key observations))
      (some (fencingCursor context continuation (RevisionFence.prepared cursor key state)), .tuple [a "prepared"])) :
    FencePreparationTrace context continuation cursor key
      (acceptFence context continuation (RevisionFence.prepare cursor key observations)) state := by
  generalize origin : acceptFence context continuation (RevisionFence.prepare cursor key observations) = output at trace
  generalize ending : (some (fencingCursor context continuation (RevisionFence.prepared cursor key state)),
    Term.tuple [a "prepared"]) = final at trace
  induction trace generalizing observations with
  | done output =>
    rw [← ending]
    exact .done state
  | @resume saved request observation final tail ih =>
    have captured := fence_prepare_observation_resource origin
    subst saved
    apply FencePreparationTrace.resume (observation := observation)
    exact ih (fence_prepare_resume_captured context continuation key observation cursor observations).symm ending

theorem input_raw_fence_prepared {cursor : PendingRevision.Cursor} {events observations : List Term}
    {key state : Term}
    (trace : ObservationTrace
      (resident (inputFenced cursor events).1 (a "fence_start") (.tuple [key, list observations]))
      (some (fencingCursor (.pending cursor) (inputFenceContinuation events)
        (RevisionFence.prepared cursor key state)), .tuple [a "prepared"])) :
    RevisionFence.Preparation cursor key
      (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) state := by
  simp only [inputFenced] at trace
  rw [fence_start_captured] at trace
  exact fence_preparation_reflect
    (fence_preparation_observations_reflect (context := .pending cursor)
      (continuation := inputFenceContinuation events) (cursor := cursor) (key := key)
      (observations := observations) trace)

end VerifiedKernel.Session.CommandDriver
