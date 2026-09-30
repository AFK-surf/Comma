import VerifiedKernelProofs.Session.WorkDriverRawFence
import VerifiedKernelProofs.Session.WorkDriverRawBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def metadataBatchCursor (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key batch : Term) : Term :=
  fencingCursor context continuation (.tuple [a "session_fence_batch", cursor.pack, key, batch])

inductive MetadataOutput (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key : Term) : Output → Prop where
  | done (state : Term) : MetadataOutput context continuation cursor key
      (some (fencingCursor context continuation (stampedFence cursor key state)), .tuple [a "stamped"])
  | run (state event : Term) (remaining : List Term) : MetadataOutput context continuation cursor key
      (some (metadataBatchCursor context continuation cursor key (BatchExecution.pending state (event :: remaining))),
        .tuple [a "next"])
  | resume (token request : Term) (remaining : List Term) : MetadataOutput context continuation cursor key
      (some (metadataBatchCursor context continuation cursor key (BatchExecution.observing token remaining)),
        .tuple [a "observe", request])
  | stopped (output : Output)
      (terminal : ∀ saved, output ≠ (some saved, .tuple [a "next"]) ∧
        ∀ request, output ≠ (some saved, .tuple [a "observe", request])) :
      MetadataOutput context continuation cursor key output

theorem metadata_next_valid (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key state : Term) (remaining : List Term) :
    MetadataOutput context continuation cursor key
      (acceptFence context continuation (RevisionFence.acceptMetadata cursor key (BatchExecution.next state remaining))) := by
  cases remaining with
  | nil => exact .done state
  | cons event remaining => exact .run state event remaining

theorem metadata_accept_valid (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key result : Term) (remaining : List Term) :
    MetadataOutput context continuation cursor key
      (acceptFence context continuation (RevisionFence.acceptMetadata cursor key (BatchExecution.accept remaining result))) := by
  unfold BatchExecution.accept
  split
  · exact metadata_next_valid _ _ _ _ _ _
  · exact .resume _ _ remaining
  · apply MetadataOutput.stopped
    intro saved
    constructor
    · intro impossible
      simp only [RevisionFence.acceptMetadata] at impossible
      unfold acceptFence at impossible
      split at impossible <;> simp_all [rejected, a]
    · intro request impossible
      simp only [RevisionFence.acceptMetadata] at impossible
      unfold acceptFence at impossible
      split at impossible <;> simp_all [rejected, a]

theorem metadata_run_captured (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key state event : Term) (remaining observations : List Term) :
    resident (some (metadataBatchCursor context continuation cursor key (BatchExecution.pending state (event :: remaining))))
      (a "run") (list observations) =
      acceptFence context continuation
        (RevisionFence.acceptMetadata cursor key (BatchExecution.accept remaining (runTrusted state event observations))) := by
  cases context <;> rfl

theorem metadata_resume_captured (context : Context) (continuation : Term)
    (cursor : PendingRevision.Cursor) (key token observation : Term) (remaining : List Term) :
    resident (some (metadataBatchCursor context continuation cursor key (BatchExecution.observing token remaining)))
      (a "resume") observation =
      acceptFence context continuation
        (RevisionFence.acceptMetadata cursor key (BatchExecution.accept remaining (resumeTrusted token observation))) := by
  cases context <;> rfl

theorem metadata_next_shape {context : Context} {continuation key saved : Term}
    {cursor : PendingRevision.Cursor}
    (valid : MetadataOutput context continuation cursor key (some saved, .tuple [a "next"])) :
    ∃ state event remaining,
      saved = metadataBatchCursor context continuation cursor key (BatchExecution.pending state (event :: remaining)) := by
  generalize same : (some saved, Term.tuple [a "next"]) = output at valid
  cases valid with
  | done => simp [a] at same
  | run state event remaining => exact ⟨state, event, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | resume => simp [a] at same
  | stopped output terminal => exact ((terminal saved).1 same.symm).elim

theorem metadata_observation_shape {context : Context} {continuation key saved request : Term}
    {cursor : PendingRevision.Cursor}
    (valid : MetadataOutput context continuation cursor key (some saved, .tuple [a "observe", request])) :
    ∃ token remaining,
      saved = metadataBatchCursor context continuation cursor key (BatchExecution.observing token remaining) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | done => simp [a] at same
  | run => simp [a] at same
  | resume token request remaining => exact ⟨token, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | stopped output terminal => exact ((terminal saved).2 request same.symm).elim

theorem metadata_trace_reflect {context : Context} {continuation key state : Term}
    {cursor : PendingRevision.Cursor} {initial : Output}
    (valid : MetadataOutput context continuation cursor key initial)
    (trace : BatchTrace initial
      (some (fencingCursor context continuation (stampedFence cursor key state)), .tuple [a "stamped"])) :
    FenceMetadataTrace context continuation cursor key initial state := by
  generalize ending : (some (fencingCursor context continuation (stampedFence cursor key state)),
    Term.tuple [a "stamped"]) = output at trace
  induction trace with
  | done output =>
    subst output
    exact .done state
  | @run saved observations output tail ih =>
    obtain ⟨before, event, remaining, rfl⟩ := metadata_next_shape valid
    apply FenceMetadataTrace.run (observations := observations)
    apply ih
    · rw [metadata_run_captured]
      exact metadata_accept_valid _ _ _ _ _ _
    · exact ending
  | @resume saved request observation output tail ih =>
    obtain ⟨token, remaining, rfl⟩ := metadata_observation_shape valid
    apply FenceMetadataTrace.resume (observation := observation)
    apply ih
    · rw [metadata_resume_captured]
      exact metadata_accept_valid _ _ _ _ _ _
    · exact ending

theorem input_raw_fence_stamped {cursor : PendingRevision.Cursor} {events : List Term}
    {key before after token reasons activity revision flush epoch node : Term}
    (trace : BatchTrace
      (resident (some (fencingCursor (.pending cursor) (inputFenceContinuation events)
        (RevisionFence.prepared cursor key before))) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node]))
      (some (fencingCursor (.pending cursor) (inputFenceContinuation events) (stampedFence cursor key after)),
        .tuple [a "stamped"])) :
    RevisionFence.MetadataExecution cursor key
      (RevisionFence.resident (some (RevisionFence.prepared cursor key before)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) after := by
  apply input_fence_stamped
  apply metadata_trace_reflect (trace := trace)
  simp only [fencingCursor]
  rw [stamp_captured]
  exact metadata_next_valid (.pending cursor) (inputFenceContinuation events) cursor key before
    (RevisionFence.metadataEvents token reasons activity revision flush epoch node)

end VerifiedKernel.Session.CommandDriver
