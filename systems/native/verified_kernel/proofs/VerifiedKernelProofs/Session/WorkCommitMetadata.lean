import VerifiedKernelProofs.Session.WorkOwnerStorage
import VerifiedKernelProofs.Session.WorkHistoryReachability

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

def CommitMetadata (event : Term) : Prop :=
  (event.get (b "type") = b "session_stamp" ∧ event.has (b "agent_id") = false) ∨
    event.get (b "type") = b "bump_hwm"

theorem stampRuntimeEpoch_owner {s e t : Term} {j r : List Term}
    (h : stampRuntimeEpoch s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampRuntimeEpoch at h
  owner_walk h

theorem stampRuntimeNode_owner {s e t : Term} {j r : List Term}
    (h : stampRuntimeNode s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampRuntimeNode at h
  owner_walk h

theorem stampActivityRevision_owner {s e t : Term} {j r : List Term}
    (h : stampActivityRevision s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampActivityRevision at h
  owner_walk h

theorem stampStorageRevision_owner {s e t : Term} {j r : List Term}
    (h : stampStorageRevision s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampStorageRevision at h
  owner_walk h

theorem stampFlushId_owner {s e t : Term} {j r : List Term}
    (h : stampFlushId s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampFlushId at h
  owner_walk h

theorem stampWorkIndexToken_owner {s e t : Term} {j r : List Term}
    (h : stampWorkIndexToken s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampWorkIndexToken at h
  owner_walk h

theorem stampWorkReasons_owner {s e t : Term} {j r : List Term}
    (h : stampWorkReasons s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold stampWorkReasons at h
  owner_walk h

theorem sessionStamp_commit_owner {s e t : Term} {j r : List Term}
    (absent : e.has (b "agent_id") = false)
    (h : sessionStamp s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold sessionStamp at h
  obtain ⟨initial, _, first, h⟩ := bind_ok h
  unfold stampAgentId at first
  simp only [absent, Bool.false_eq_true, ↓reduceIte] at first
  have same := pure_ok first
  subst initial
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampRuntimeEpoch_owner step)
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampRuntimeNode_owner step)
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampActivityRevision_owner step)
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampStorageRevision_owner step)
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampFlushId_owner step)
  obtain ⟨_, _, step, h⟩ := bind_ok h
  refine Eq.trans ?_ (stampWorkIndexToken_owner step)
  exact stampWorkReasons_owner h

theorem bumpHwmEvent_owner {s e t : Term} {j r : List Term}
    (h : bumpHwmEvent s e j = .ok (t, r)) : OwnerFrame s t := by
  unfold bumpHwmEvent at h
  owner_compose h

theorem commit_metadata_inner_frames {s e t : Term} {j r : List Term}
    (metadata : CommitMetadata e) (h : inner s e j = .ok (t, r)) :
    QueueFrame s t ∧ TranscriptExtends s t ∧ OwnerFrame s t := by
  rcases metadata with ⟨kind, absent⟩ | kind
  · have call : sessionStamp s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    exact ⟨sessionStamp_queue_frame call, sessionStamp_extends call, sessionStamp_commit_owner absent call⟩
  · have call : bumpHwmEvent s e j = .ok (t, r) := by simpa +decide [inner, kind] using h
    exact ⟨bumpHwmEvent_queue_frame call, bumpHwmEvent_extends call, bumpHwmEvent_owner call⟩

theorem commit_metadata_resident_frames {s e t : Term}
    (step : ResidentStep s e t) (canonical : BinaryKeys e) (metadata : CommitMetadata e) :
    QueueFrame s t ∧ TranscriptExtends s t ∧ OwnerFrame s t := by
  obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := step
  have activityFrames := activity_frame_queue activity
  have activityRecords := activity_frame_extends activity
  have activityOwner := activity "agent_id" (by decide) (by decide)
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activityFrames activityRecords activityOwner
    exact ⟨activityFrames, activityRecords, activityOwner⟩
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    obtain ⟨queue, records, owner⟩ := commit_metadata_inner_frames metadata call
    exact ⟨queue_frame_trans queue activityFrames, extends_trans records activityRecords, activityOwner.trans owner⟩

theorem commit_metadata_batch_frames {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event) :
    QueueFrame s t ∧ TranscriptExtends s t ∧ OwnerFrame s t := by
  induction execution with
  | nil => exact ⟨queue_frame_refl _, extends_refl _, rfl⟩
  | cons first rest ih =>
    obtain ⟨queue, records, owner⟩ := commit_metadata_resident_frames
      (resident_execution_step first) (canonical _ List.mem_cons_self) (metadata _ List.mem_cons_self)
    obtain ⟨nextQueue, nextRecords, nextOwner⟩ := ih
      (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => metadata event (List.mem_cons_of_mem _ member))
    exact ⟨queue_frame_trans queue nextQueue, extends_trans records nextRecords, nextOwner.trans owner⟩

theorem commit_metadata_batch_preserves {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event)
    (ready : QueueReady s) (reachable : HistoryReachable s) :
    QueueReady t ∧ HistoryReachable t ∧ OwnerFrame s t ∧
      ∀ sealed item, ValueSemantics.Represented s sealed item → ValueSemantics.Represented t sealed item := by
  obtain ⟨queue, records, owner⟩ := commit_metadata_batch_frames execution canonical metadata
  refine ⟨queue_frame_ready queue ready, .batch reachable execution, owner, ?_⟩
  intro sealed item represented
  exact ValueSemantics.execution_preserves
    (fun _ present => concrete_representation_frame_extends queue.1 records present)
    (fun _ present => record_survives records present) represented

end VerifiedKernel.Session.WorkConservation
