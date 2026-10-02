import VerifiedKernelProofs.Session.WorkLifecycle

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096
set_option Elab.async false

theorem normalize_format {s t : Term} {format : Int} {j r : List Term}
    (stored : s.get (a "storage_format") = i format)
    (h : Lifecycle.normalize s j = .ok (t, r)) :
    t.get (a "storage_format") = i format := by
  have initial := fillDefaults_get (key := "storage_format") (s := s)
    (by rw [stored]; intro impossible; cases impossible)
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_field_is h "storage_format"; change (field (Lifecycle.fillDefaults s) "storage_format" >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨value, _, read, h⟩ := bind_ok h
  have same := (field_value read).trans (initial.trans stored)
  subst value
  repeat
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have selected : normalized.get (a "storage_format") = i format := write_get_key "storage_format" written rfl
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, providerWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact (write_field_frame h rfl).trans
    ((write_field_frame providerWrite rfl).trans ((write_field_frame activityWrite rfl).trans selected))

theorem persistable_queue_frame {s t : Term} {j r : List Term}
    (h : Lifecycle.persistable s j = .ok (t, r)) : QueueFrame s t := by
  have same := put_ok h
  rw [same]
  exact ⟨get_put_other _ _ (by decide), get_put_other _ _ (by decide),
    get_put_other _ _ (by decide), get_put_other _ _ (by decide), get_put_other _ _ (by decide)⟩

theorem persistable_work_fields {s t : Term} {j r : List Term}
    (h : Lifecycle.persistable s j = .ok (t, r)) : WorkFieldsPreserved s t := by
  have same := put_ok h
  rw [same]
  exact ⟨get_put_other _ _ (by decide), get_put_other _ _ (by decide)⟩

theorem persistable_preserves {s t : Term} {j r : List Term}
    (ready : QueueReady s) (h : Lifecycle.persistable s j = .ok (t, r)) :
    QueueReady t ∧ ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item :=
  ⟨queue_frame_ready (persistable_queue_frame h) ready,
    fun _ _ present => (concrete_representation_frame (persistable_work_fields h)).mp present⟩

theorem prepareWrite_modern {s result : Term} {format : Int} {j r : List Term}
    (stored : s.get (a "storage_format") = i format) (modern : format = 2 ∨ format = 3)
    (ready : QueueReady s) (h : Lifecycle.prepareWrite s j = .ok (result, r)) :
    ∃ t, result = .tuple [a "ok", t] ∧ t.get (a "storage_format") = i 3 ∧ QueueReady t ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normalizedRead, h⟩ := bind_ok h
  have formatRead := normalize_format stored normalizedRead
  have normalizedReady := (normalize_work ready normalizedRead).1
  obtain ⟨value, _, valueRead, h⟩ := bind_ok h
  have same := (field_value valueRead).trans formatRead
  subst value
  have notLegacy : (i format == i 1) = false := by rcases modern with rfl | rfl <;> rfl
  have supported : (i format == i 2 || i format == i 3) = true := by rcases modern with rfl | rfl <;> rfl
  simp only [notLegacy, Bool.false_eq_true, supported, ↓reduceIte] at h
  obtain ⟨t, _, written, h⟩ := bind_ok h
  have fields : WorkFieldsPreserved normalized t := ⟨write_field_frame written rfl, write_field_frame written rfl⟩
  have allocation : QueueAllocated t := by
    obtain ⟨items, next, queue, allocator, positive, canonical, bounded, unique⟩ := normalizedReady.1
    exact ⟨items, next, (write_field_frame written rfl).trans queue,
      (write_field_frame written rfl).trans allocator, positive, canonical, bounded, unique⟩
  have live : QueueUnacked t := by
    obtain ⟨items, ack, queue, watermark, above⟩ := normalizedReady.2.1
    exact ⟨items, ack, (write_field_frame written rfl).trans queue,
      (write_field_frame written rfl).trans watermark, above⟩
  refine ⟨t, pure_ok h, ?_, ⟨allocation, live, ?_⟩, ?_⟩
  · obtain ⟨_, written⟩ := write_cons written
    rw [pure_ok written]
    exact get_put_same _ _ _
  · simpa only [write_field_frame written (show [("storage_format", i 3)].all (fun pair => pair.1 != "queue_ack_id") = true from rfl),
      write_field_frame written (show [("storage_format", i 3)].all (fun pair => pair.1 != "next_queue_id") = true from rfl)] using normalizedReady.2.2
  · intro sealed item present
    exact (concrete_representation_frame fields).mp (normalize_representation ready normalizedRead present)

end VerifiedKernel.Session.WorkConservation
