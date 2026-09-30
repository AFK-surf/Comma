import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkArchiveOrder
import VerifiedKernelProofs.Session.WorkInitialFormat

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem maxStamped_empty (j : List Term) :
    Lifecycle.maxStamped (list []) (list []) (list []) j = .ok (i 0, j) := rfl

theorem normalizeLastSeq_empty {s value : Term} {j r : List Term}
    (messages : s.get (a "messages") = list []) (events : s.get (a "events") = list [])
    (results : s.get (a "async_results") = list []) (last : s.get (a "last_seq") = i 0)
    (h : Lifecycle.normalizeLastSeq s j = .ok (value, r)) : value = i 0 := by
  unfold Lifecycle.normalizeLastSeq at h
  obtain ⟨stored, _, storedRead, h⟩ := bind_ok h
  have same := (field_value storedRead).trans last
  subst stored
  obtain ⟨ms, _, msRead, h⟩ := bind_ok h
  have same := (field_value msRead).trans messages
  subst ms
  obtain ⟨es, _, esRead, h⟩ := bind_ok h
  have same := (field_value esRead).trans events
  subst es
  obtain ⟨rs, _, rsRead, h⟩ := bind_ok h
  have same := (field_value rsRead).trans results
  subst rs
  obtain ⟨stamped, _, stampedRead, h⟩ := bind_ok h
  simp only [Term.default, Term.truthy, ↓reduceIte, maxStamped_empty] at stampedRead
  have same := (Prod.mk.inj (Except.ok.inj stampedRead)).1
  subst stamped
  simp only [default_integer, kmax_integer] at h
  exact (Prod.mk.inj (Except.ok.inj h)).1.symm

theorem normalize_sequence_value {s t : Term} {j r : List Term}
    (h : Lifecycle.normalize s j = .ok (t, r)) :
    ∃ value first last, Lifecycle.normalizeLastSeq (Lifecycle.fillDefaults s) first = .ok (value, last) ∧
      t.get (a "last_seq") = value := by
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_head_is h [Lifecycle.normalizeLastSeq]; change (Lifecycle.normalizeLastSeq (Lifecycle.fillDefaults s) >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨value, last, read, h⟩ := bind_ok h
  repeat
    fail_if_success (bind_head_is h [write]; change (write _ _ >>= _) _ = _ at h)
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have selected : normalized.get (a "last_seq") = value := by
    repeat
      first
      | exact (write_field_frame written rfl).trans (get_put_same _ _ _)
      | obtain ⟨_, written⟩ := write_cons written
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, providerWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact ⟨value, _, last, read, (write_field_frame h rfl).trans
    ((write_field_frame providerWrite rfl).trans ((write_field_frame activityWrite rfl).trans selected))⟩

theorem normalize_empty_sequence {s t : Term} {j r : List Term} (ready : QueueReady s)
    (messages : s.get (a "messages") = list []) (events : s.get (a "events") = list [])
    (results : s.get (a "async_results") = list []) (last : s.get (a "last_seq") = i 0)
    (h : Lifecycle.normalize s j = .ok (t, r)) : SeqSorted t := by
  have ms := fillDefaults_get (s := s) (key := "messages") (by rw [messages]; intro impossible; cases impossible)
  have es := fillDefaults_get (s := s) (key := "events") (by rw [events]; intro impossible; cases impossible)
  have rs := fillDefaults_get (s := s) (key := "async_results") (by rw [results]; intro impossible; cases impossible)
  have stamp := fillDefaults_get (s := s) (key := "last_seq") (by rw [last]; intro impossible; cases impossible)
  obtain ⟨value, first, rest, actual, valueRead⟩ := normalize_sequence_value h
  have zero := normalizeLastSeq_empty (ms.trans messages) (es.trans events) (rs.trans results) (stamp.trans last) actual
  have nextMessages := (normalize_work ready h).2.2
  rw [ms, messages] at nextMessages
  refine ⟨[], 0, nextMessages, ?_, by simp, List.Pairwise.nil⟩
  rw [lastSeq, valueRead, zero, default_integer]

theorem create_sequence_invariant {s args t : Term} {j r : List Term}
    (h : Lifecycle.create s args j = .ok (t, r)) : SeqSorted t := by
  unfold Lifecycle.create at h
  split at h
  · repeat
      fail_if_success (head_is h [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (t, r) at h)
      obtain ⟨_, _, _, h⟩ := bind_ok h
    exact normalize_empty_sequence (build_ready rfl rfl rfl)
      ((build_get rfl).trans rfl) ((build_get rfl).trans rfl)
      ((build_get rfl).trans rfl) ((build_get rfl).trans rfl) h
  · exact (fail_ok h).elim

end VerifiedKernel.Session.WorkConservation
