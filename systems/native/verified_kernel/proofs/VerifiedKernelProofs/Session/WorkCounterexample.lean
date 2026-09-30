import VerifiedKernelProofs.Session.WorkProtocol

namespace VerifiedKernel.Session.WorkConservation.Counterexample
open Data

def item : Term := .map [
  (b "queue_id", i 1), (b "kind", b "user_message"),
  (b "payload", .map [(b "source_message_id", b "original"), (b "content", b "work")])]

def before : Term := .map [
  (a "input_queue", list [item]), (a "messages", list []),
  (a "segment_catalog", list []), (a "async_result_refs", empty)]

def event : Term := .map [(b "type", b "queue_consume"), (b "queue_id", i 1)]

def after : Term := before.put (a "input_queue") (list [])

/-- The executable reducer can remove work without a record or an archive transfer. -/
theorem consume_without_record : queueConsume before event [] = .ok (after, []) := by
  cbv

theorem removed_facts :
    after.get (a "input_queue") = list [] ∧
    after.get (a "messages") = list [] ∧
    after.get (a "segment_catalog") = list [] := by
  exact ⟨rfl, rfl, rfl⟩

/-- This removal has no matching abstract step under the work-preserving projection. -/
theorem no_snapshot_step : ¬SnapshotStep { queued := [item] } {} := by
  intro step
  have preserved := snapshot_step_preserves step item (Or.inl (by simp))
  simp [Represented] at preserved

end VerifiedKernel.Session.WorkConservation.Counterexample
