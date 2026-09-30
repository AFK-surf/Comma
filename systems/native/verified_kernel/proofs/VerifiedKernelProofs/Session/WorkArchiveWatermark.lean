import VerifiedKernelProofs.Session.WorkArchiveInvariant

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem archiveAdvance_watermark {state event next : Term} {base : Int} {journal rest : List Term}
    (read : state.get (a "archived_through") = i base)
    (call : archiveAdvance state event journal = .ok (next, rest)) :
    ∃ watermark : Int, next.get (a "archived_through") = i watermark ∧ base ≤ watermark := by
  have unchanged (same : next = state) :
      ∃ watermark : Int, next.get (a "archived_through") = i watermark ∧ base ≤ watermark :=
    ⟨base, by rwa [same], Int.le_refl _⟩
  unfold archiveAdvance at call
  obtain ⟨through, _, _, call⟩ := bind_ok call
  obtain ⟨segments, _, _, call⟩ := bind_ok call
  split at call
  · exact unchanged (pure_ok call)
  · rename_i kinds
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] at kinds
    obtain ⟨watermark, integerEq⟩ := isInteger_exists kinds.2
    subst through
    obtain ⟨stored, _, storedRead, call⟩ := bind_ok call
    have same := (field_value storedRead).trans read
    subst stored
    obtain ⟨ahead, _, comparison, call⟩ := bind_ok call
    simp only [i, default_integer, greater_integer] at comparison
    have same := (Prod.mk.inj (Except.ok.inj comparison)).1.symm
    subst ahead
    split at call
    · exact unchanged (pure_ok call)
    · rename_i rising
      have rising : base < watermark := by simpa using rising
      obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain ⟨_, _, _, call⟩ := bind_ok call
      split at call
      · exact unchanged (pure_ok call)
      · repeat
          fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = .ok (next, rest) at call)
          obtain ⟨_, _, _, call⟩ := bind_ok call
        obtain ⟨advanced, _, written, call⟩ := bind_ok call
        obtain ⟨pruned, _, prunedCall, call⟩ := bind_ok call
        refine ⟨watermark, ?_, Int.le_of_lt rising⟩
        rw [recomputeContext_field (key := "archived_through") (by decide) call,
          pruneResultRefs_field (key := "archived_through") (by decide) prunedCall]
        exact write_get_key "archived_through" written rfl

def ArchiveNonnegative (state : Term) : Prop :=
  ∃ watermark : Int, state.get (a "archived_through") = i watermark ∧ 0 ≤ watermark

theorem InitialFields.archive_nonnegative {state : Term} (initial : InitialFields state) : ArchiveNonnegative state :=
  ⟨0, initial.archived, Int.le_refl _⟩

theorem ArchiveNonnegative.fields {state next : Term}
    (field : next.get (a "archived_through") = state.get (a "archived_through"))
    (before : ArchiveNonnegative state) : ArchiveNonnegative next := by
  obtain ⟨watermark, read, positive⟩ := before
  exact ⟨watermark, field.trans read, positive⟩

theorem ArchiveNonnegative.advance {state event next : Term} {journal rest : List Term}
    (before : ArchiveNonnegative state) (call : archiveAdvance state event journal = .ok (next, rest)) :
    ArchiveNonnegative next := by
  obtain ⟨base, read, positive⟩ := before
  obtain ⟨watermark, nextRead, rising⟩ := archiveAdvance_watermark read call
  exact ⟨watermark, nextRead, Int.le_trans positive rising⟩

end VerifiedKernel.Session.WorkConservation
