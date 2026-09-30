import VerifiedKernelProofs.Session.AppendOnly.SeqHistory
import VerifiedKernelProofs.Session.AppendOnly

/-!
Every dispatched event preserves the `seq` invariant: transcript stamps are integers,
nondecreasing along the list, and at most `last_seq`. Together with `archiveAdvance_suffix`
this discharges the ordering hypothesis of the archive theorem for any state reachable
from a state that satisfies the invariant, such as the empty transcript.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

/-- The initial state: no messages and no `last_seq`. -/
theorem seq_sorted_empty {state : Term} (messages : state.get (a "messages") = .list [])
    (last : state.get (a "last_seq") = nil) : SeqSorted state :=
  ⟨[], 0, messages, by simp [lastSeq, last, Term.default, Term.truthy, nil], by simp, List.Pairwise.nil⟩

/-- Every dispatched event, including compaction, microcompact and archive, keeps the invariant. -/
theorem inner_seq {state event next : Term} {journal rest : List Term}
    (h : inner state event journal = .ok (next, rest)) : SeqStep state next := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  sorted_walk h

theorem prepare_seq {state raw next event : Term} {journal rest : List Term}
    (h : prepare state raw journal = .ok ((next, some event), rest)) : SeqStep state next := by
  obtain ⟨_, _, _, hn⟩ := prepare_stringify h
  exact inner_seq hn

theorem run_done_seq {state raw next : Term} {journal : List Term}
    (h : run state raw journal = .tuple [a "done", next]) : SeqStep state next := by
  unfold run at h
  split at h
  · not_done h
  split at h
  · rename_i n hp
    injection h with h₁
    injection h₁ with h₂ h₃
    injection h₃ with h₄
    obtain rfl := prepare_none hp
    subst h₄
    exact seq_refl _
  · not_done h
  · rename_i n normalized rest hp
    obtain ⟨rest', hs, _, hn⟩ := prepare_stringify hp
    have step : SeqStep state n := inner_seq hn
    unfold runActivity at h
    split at h
    · rename_i d ha
      injection h with h₁
      injection h₁ with h₂ h₃
      injection h₃ with h₄
      subst h₄
      exact seq_trans step (afterEvent_seq ha)
    · not_done h
    · not_done h
    · not_done h
  · not_done h
  · not_done h

/-- With the invariant in hand, `archive_advance` removes exactly a prefix. -/
theorem archiveAdvance_prefix {s e t : Term} {j r : List Term} {xs : List Term} (inv : SeqSorted s)
    (read : s.get (a "messages") = .list xs)
    (plain : ∀ m ∈ xs, (m.isMap && !m.has (a "__struct__")) = true)
    (h : archiveAdvance s e j = .ok (t, r)) :
    ∃ dropped kept, xs = dropped ++ kept ∧ t.get (a "messages") = .list kept ∧
      ∀ m ∈ dropped, integerValue (m.get (a "seq")) ≤ integerValue (e.get (b "archived_through")) := by
  obtain ⟨xs', n, hread, -, hstamped, hsorted⟩ := inv
  rw [read] at hread
  obtain rfl := Term.list.inj hread
  exact archiveAdvance_suffix read plain (fun m hm => (hstamped m hm).imp fun _ hk => hk.1) hsorted h

end VerifiedKernel.Session
