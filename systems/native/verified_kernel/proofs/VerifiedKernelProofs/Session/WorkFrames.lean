import VerifiedKernelProofs.Session.AppendOnly.Core

namespace VerifiedKernel.Session.WorkConservation
open Data

set_option maxHeartbeats 2000000
set_option Elab.async false

def QueuePreserved (s t : Term) : Prop := t.get (a "input_queue") = s.get (a "input_queue")

theorem queue_refl (s : Term) : QueuePreserved s s := rfl

theorem queue_trans {s t u : Term} (first : QueuePreserved s t) (second : QueuePreserved t u) :
    QueuePreserved s u := second.trans first

theorem write_field_frame {s t : Term} {entries : List (String × Term)} {key : String} {j r : List Term}
    (h : write s entries j = .ok (t, r)) (ok : entries.all (fun e => e.1 != key) = true) :
    t.get (a key) = s.get (a key) := by
  induction entries generalizing s j with
  | nil =>
    have eq := pure_ok h
    subst t
    rfl
  | cons entry rest ih =>
    obtain ⟨name, value⟩ := entry
    simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at ok
    obtain ⟨j', h⟩ := write_cons h
    rw [ih h ok.2, get_put_other _ _ ok.1]

theorem write_queue_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun e => e.1 != "input_queue") = true → QueuePreserved s t) :=
  step_iff fun h ok => write_field_frame h ok

syntax "queue_step" ident : tactic
macro_rules
  | `(tactic| queue_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_queue_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine queue_trans (kept rfl) ?_)
      | (head_step $h "_queue_step"; obtain ⟨_, kept⟩ := $h; refine queue_trans kept ?_))

syntax "queue_walk" ident : tactic
macro_rules
  | `(tactic| queue_walk $h:ident) =>
    `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact queue_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (queue_step $h; exact queue_refl _)
      | split at $h:ident
      | ((obtain ⟨_, _, hx, $h:ident⟩ := bind_ok $h)
         first
           | (head_is hx [Pure.pure]; simp only [pure_ok_iff] at hx; cases hx)
           | queue_step hx
           | (split at hx <;> first
               | (head_is hx [Pure.pure]; simp only [pure_ok_iff] at hx; cases hx)
               | queue_step hx
               | ((repeat (fail_if_success queue_step hx; obtain ⟨_, _, _, hx⟩ := bind_ok hx))
                  queue_step hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem pruneResultRefs_queue {s t : Term} {j r : List Term}
    (h : pruneResultRefs s j = .ok (t, r)) : QueuePreserved s t := by
  unfold pruneResultRefs at h
  queue_walk h

theorem pruneResultRefs_queue_step {s t : Term} {j r : List Term} :
    pruneResultRefs s j = .ok (t, r) ↔ Except.ok (t, r) = pruneResultRefs s j ∧ QueuePreserved s t :=
  step_iff pruneResultRefs_queue

theorem pruneCompactResults_queue {s t : Term} {j r : List Term}
    (h : pruneCompactResults s j = .ok (t, r)) : QueuePreserved s t := by
  unfold pruneCompactResults at h
  queue_walk h

theorem pruneCompactResults_queue_step {s t : Term} {j r : List Term} :
    pruneCompactResults s j = .ok (t, r) ↔ Except.ok (t, r) = pruneCompactResults s j ∧ QueuePreserved s t :=
  step_iff pruneCompactResults_queue

theorem recomputeContext_queue {s t : Term} {j r : List Term}
    (h : recomputeContext s j = .ok (t, r)) : QueuePreserved s t := by
  unfold recomputeContext at h
  queue_walk h

theorem recomputeContext_queue_step {s t : Term} {j r : List Term} :
    recomputeContext s j = .ok (t, r) ↔ Except.ok (t, r) = recomputeContext s j ∧ QueuePreserved s t :=
  step_iff recomputeContext_queue

/-- Both normal and provider compaction preserve every queued payload, including late input. -/
theorem compaction_preserves_queue {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : QueuePreserved s t := by
  unfold historyCompaction at h
  queue_walk h

/-- Moving journal records to sealed storage does not remove pending inputs. -/
theorem archive_preserves_queue {s e t : Term} {j r : List Term}
    (h : archiveAdvance s e j = .ok (t, r)) : QueuePreserved s t := by
  unfold archiveAdvance at h
  queue_walk h

end VerifiedKernel.Session.WorkConservation
