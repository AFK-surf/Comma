import VerifiedKernelProofs.Session.WorkArchiveCommit
import VerifiedKernelProofs.Session.WorkCommitMetadata

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

def ArchiveFrame (s t : Term) : Prop :=
  t.get (a "segment_catalog") = s.get (a "segment_catalog") ∧
  t.get (a "archived_through") = s.get (a "archived_through") ∧
  t.get (a "session_id") = s.get (a "session_id")

theorem ArchiveFrame.refl (s : Term) : ArchiveFrame s s := ⟨rfl, rfl, rfl⟩

theorem ArchiveFrame.trans {s t u : Term} (first : ArchiveFrame s t) (last : ArchiveFrame t u) : ArchiveFrame s u :=
  ⟨last.1.trans first.1, last.2.1.trans first.2.1, last.2.2.trans first.2.2⟩

theorem write_archive_frame {s t : Term} {fields : List (String × Term)} {j r : List Term}
    (h : write s fields j = .ok (t, r))
    (catalog : fields.all (fun pair => pair.1 != "segment_catalog") = true)
    (watermark : fields.all (fun pair => pair.1 != "archived_through") = true)
    (session : fields.all (fun pair => pair.1 != "session_id") = true) : ArchiveFrame s t :=
  ⟨write_field_frame h catalog, write_field_frame h watermark, write_field_frame h session⟩

syntax "archive_frame_walk" ident : tactic
macro_rules
  | `(tactic| archive_frame_walk $h:ident) =>
    `(tactic| repeat' first
      | (head_is $h [write]; exact write_archive_frame $h rfl rfl rfl)
      | (head_is $h [Pure.pure]; rw [pure_ok $h]; exact ArchiveFrame.refl _)
      | (head_is $h [VerifiedKernel.fail, argumentError, inspectedError]; exact (fail_ok $h).elim)
      | split at $h:ident
      | (obtain ⟨_, _, _, $h:ident⟩ := bind_ok $h)
      | dsimp only at $h:ident)

theorem stampAgentId_archive_frame {s e t : Term} {j r : List Term}
    (h : stampAgentId s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampAgentId at h
  archive_frame_walk h

theorem stampRuntimeEpoch_archive_frame {s e t : Term} {j r : List Term}
    (h : stampRuntimeEpoch s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampRuntimeEpoch at h
  archive_frame_walk h

theorem stampRuntimeNode_archive_frame {s e t : Term} {j r : List Term}
    (h : stampRuntimeNode s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampRuntimeNode at h
  archive_frame_walk h

theorem stampActivityRevision_archive_frame {s e t : Term} {j r : List Term}
    (h : stampActivityRevision s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampActivityRevision at h
  archive_frame_walk h

theorem stampStorageRevision_archive_frame {s e t : Term} {j r : List Term}
    (h : stampStorageRevision s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampStorageRevision at h
  archive_frame_walk h

theorem stampFlushId_archive_frame {s e t : Term} {j r : List Term}
    (h : stampFlushId s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampFlushId at h
  archive_frame_walk h

theorem stampWorkIndexToken_archive_frame {s e t : Term} {j r : List Term}
    (h : stampWorkIndexToken s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampWorkIndexToken at h
  archive_frame_walk h

theorem stampWorkReasons_archive_frame {s e t : Term} {j r : List Term}
    (h : stampWorkReasons s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold stampWorkReasons at h
  archive_frame_walk h

theorem bumpHwm_archive_frame {s e t : Term} {j r : List Term}
    (h : bumpHwm s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold bumpHwm at h
  archive_frame_walk h

theorem sessionStamp_archive_frame {s e t : Term} {j r : List Term}
    (h : sessionStamp s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold sessionStamp at h
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampAgentId_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampRuntimeEpoch_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampRuntimeNode_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampActivityRevision_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampStorageRevision_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampFlushId_archive_frame call).trans
  obtain ⟨_, _, call, h⟩ := bind_ok h
  apply (stampWorkIndexToken_archive_frame call).trans
  exact stampWorkReasons_archive_frame h

theorem bumpHwmEvent_archive_frame {s e t : Term} {j r : List Term}
    (h : bumpHwmEvent s e j = .ok (t, r)) : ArchiveFrame s t := by
  unfold bumpHwmEvent at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact bumpHwm_archive_frame h

theorem metadata_inner_archive_frame {s e t : Term} {j r : List Term}
    (metadata : CommitMetadata e) (h : inner s e j = .ok (t, r)) : ArchiveFrame s t := by
  rcases metadata with ⟨kind, _⟩ | kind
  · apply sessionStamp_archive_frame
    simpa +decide [inner, kind] using h
  · apply bumpHwmEvent_archive_frame
    simpa +decide [inner, kind] using h

theorem metadata_resident_archive_frame {s e t : Term}
    (step : ResidentStep s e t) (canonical : BinaryKeys e) (metadata : CommitMetadata e) : ArchiveFrame s t := by
  obtain ⟨reduced, normalized, j, r, prepared, activity⟩ := step
  have frames : ArchiveFrame reduced t := ⟨activity "segment_catalog" (by decide) (by decide),
    activity "archived_through" (by decide) (by decide), activity "session_id" (by decide) (by decide)⟩
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at frames
    exact frames
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact (metadata_inner_archive_frame metadata call).trans frames

theorem metadata_batch_archive_frame {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event) : ArchiveFrame s t := by
  induction execution with
  | nil => exact ArchiveFrame.refl _
  | cons first rest ih =>
    exact (metadata_resident_archive_frame (resident_execution_step first)
      (canonical _ List.mem_cons_self) (metadata _ List.mem_cons_self)).trans
      (ih (fun event member => canonical event (List.mem_cons_of_mem _ member))
        (fun event member => metadata event (List.mem_cons_of_mem _ member)))

end VerifiedKernel.Session.ArchivePublication
