import VerifiedKernelProofs.Session.WorkDriverBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def fencingCursor (context : Context) (continuation fence : Term) : Term :=
  .tuple [a "session_command_driver_fencing", context.pack, continuation, fence]

theorem accept_fence_wrapped {context : Context} {continuation fence response : Term} {inner : Output}
    (h : acceptFence context continuation inner = (some (fencingCursor context continuation fence), response)) :
    inner = (some fence, response) := by
  unfold acceptFence at h
  split at h
  · simp [rejected, fencingCursor, a] at h
  · simp only [fencingCursor, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
      List.cons.injEq, and_true, true_and] at h
    obtain ⟨rfl, rfl⟩ := h
    rfl
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem fence_resume_captured (context : Context) (continuation fence observation : Term) :
    resident (some (fencingCursor context continuation fence)) (a "resume") observation =
      acceptFence context continuation (RevisionFence.resident (some fence) (a "resume") observation) := by
  cases context <;> rfl

theorem fence_run_captured (context : Context) (continuation fence observations : Term) :
    resident (some (fencingCursor context continuation fence)) (a "run") observations =
      acceptFence context continuation (RevisionFence.resident (some fence) (a "run") observations) := by
  cases context <;> rfl

inductive FencePreparationTrace (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key : Term) : Output → Term → Prop where
  | done (state : Term) : FencePreparationTrace context continuation cursor key
      (some (fencingCursor context continuation (RevisionFence.prepared cursor key state)),
        .tuple [a "prepared"]) state
  | resume {observations : List Term} {request observation final : Term}
      (tail : FencePreparationTrace context continuation cursor key
        (resident (some (fencingCursor context continuation
          (.tuple [a "session_fence_preparing", cursor.pack, key, list observations])))
          (a "resume") observation) final) :
      FencePreparationTrace context continuation cursor key
        (some (fencingCursor context continuation
          (.tuple [a "session_fence_preparing", cursor.pack, key, list observations])),
          .tuple [a "observe", request]) final

theorem fence_preparation_reflect {context : Context} {continuation key final : Term}
    {cursor : PendingRevision.Cursor} {inner : Output}
    (trace : FencePreparationTrace context continuation cursor key (acceptFence context continuation inner) final) :
    RevisionFence.Preparation cursor key inner final := by
  generalize origin : acceptFence context continuation inner = output at trace
  induction trace generalizing inner with
  | done state =>
    rw [accept_fence_wrapped origin]
    exact .done state
  | @resume observations request observation final tail ih =>
    rw [accept_fence_wrapped origin]
    apply RevisionFence.Preparation.resume (observation := observation)
    exact ih (fence_resume_captured _ _ _ _).symm

def stampedFence (cursor : PendingRevision.Cursor) (key state : Term) : Term :=
  .tuple [a "session_fence_stamped", cursor.pack, key, state]

inductive FenceMetadataTrace (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key : Term) : Output → Term → Prop where
  | done (state : Term) : FenceMetadataTrace context continuation cursor key
      (some (fencingCursor context continuation (stampedFence cursor key state)), .tuple [a "stamped"]) state
  | run {state event final : Term} {events observations : List Term}
      (tail : FenceMetadataTrace context continuation cursor key
        (resident (some (fencingCursor context continuation
          (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.pending state (event :: events)])))
          (a "run") (list observations)) final) :
      FenceMetadataTrace context continuation cursor key
        (some (fencingCursor context continuation
          (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.pending state (event :: events)])),
          .tuple [a "next"]) final
  | resume {token request observation final : Term} {events : List Term}
      (tail : FenceMetadataTrace context continuation cursor key
        (resident (some (fencingCursor context continuation
          (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.observing token events])))
          (a "resume") observation) final) :
      FenceMetadataTrace context continuation cursor key
        (some (fencingCursor context continuation
          (.tuple [a "session_fence_batch", cursor.pack, key, BatchExecution.observing token events])),
          .tuple [a "observe", request]) final

theorem fence_metadata_reflect {context : Context} {continuation key final : Term}
    {cursor : PendingRevision.Cursor} {inner : Output}
    (trace : FenceMetadataTrace context continuation cursor key (acceptFence context continuation inner) final) :
    RevisionFence.MetadataExecution cursor key inner final := by
  generalize origin : acceptFence context continuation inner = output at trace
  induction trace generalizing inner with
  | done state =>
    rw [accept_fence_wrapped origin]
    exact .done state
  | @run state event final events observations tail ih =>
    rw [accept_fence_wrapped origin]
    apply RevisionFence.MetadataExecution.run (observations := observations)
    exact ih (fence_run_captured _ _ _ _).symm
  | @resume token request observation final events tail ih =>
    rw [accept_fence_wrapped origin]
    apply RevisionFence.MetadataExecution.resume (observation := observation)
    exact ih (fence_resume_captured _ _ _ _).symm

theorem input_fence_prepared {cursor : PendingRevision.Cursor} {events observations : List Term}
    {key state : Term}
    (trace : FencePreparationTrace (.pending cursor) (inputFenceContinuation events) cursor key
      (resident (inputFenced cursor events).1 (a "fence_start") (.tuple [key, list observations])) state) :
    RevisionFence.Preparation cursor key
      (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) state := by
  simp only [inputFenced] at trace
  rw [fence_start_captured] at trace
  exact fence_preparation_reflect trace

theorem input_fence_stamped {cursor : PendingRevision.Cursor} {events : List Term}
    {key before after token reasons activity revision flush epoch node : Term}
    (trace : FenceMetadataTrace (.pending cursor) (inputFenceContinuation events) cursor key
      (resident (some (fencingCursor (.pending cursor) (inputFenceContinuation events)
        (RevisionFence.prepared cursor key before))) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) after) :
    RevisionFence.MetadataExecution cursor key
      (RevisionFence.resident (some (RevisionFence.prepared cursor key before)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) after := by
  simp only [fencingCursor] at trace
  rw [stamp_captured] at trace
  exact fence_metadata_reflect trace

end VerifiedKernel.Session.CommandDriver
