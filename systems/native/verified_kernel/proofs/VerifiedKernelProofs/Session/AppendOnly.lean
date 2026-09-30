import VerifiedKernelProofs.Order
import VerifiedKernelProofs.Session.AppendOnly.Runtime
import VerifiedKernelProofs.Session.AppendOnly.Archive

/-!
The Session transcript is the `messages` field of the state envelope.
This module proves that every event reducer used by runtime dispatch, apart from
`archive_advance` and `session_microcompact`, keeps the existing transcript as a
prefix of the next transcript. Compaction (`compaction`, `provider_compaction`,
`session_compact_result`, `compaction_failure`, `compaction_recovery`) never
rewrites the message list; it only moves watermarks and summaries.
`AppendOnly/Archive.lean` covers the remaining event: `archive_advance` removes a prefix and
nothing else.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

/-! ### Dispatch -/

/-- Every dispatched event except `archive_advance` and legacy `session_microcompact`
appends to the transcript or leaves it unchanged. -/
theorem inner_extends {state event next : Term} {journal rest : List Term}
    (notMicrocompact : (event.get (b "type") == b "session_microcompact") = false)
    (notArchive : (event.get (b "type") == b "archive_advance") = false)
    (h : inner state event journal = .ok (next, rest)) : TranscriptExtends state next := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  transcript_walk h
  all_goals first
    | exact absurd ‹(event.get (b "type") == b "session_microcompact") = true› (by simp [notMicrocompact])
    | exact absurd ‹(event.get (b "type") == b "archive_advance") = true› (by simp [notArchive])

/-- A prepared event that reaches `inner` was normalized by `shallowStringify` on the same journal. -/
theorem prepare_stringify {state raw next event : Term} {journal rest : List Term}
    (h : prepare state raw journal = .ok ((next, some event), rest)) :
    ∃ rest', shallowStringify raw journal = .ok (event, rest') ∧
      ∃ rest'', inner state event rest' = .ok (next, rest'') := by
  unfold prepare at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    pure_ok_iff, Prod.mk.injEq, reduceCtorEq, Option.some.injEq] at h
  obtain ⟨-, -, normalized, rest', hs, -, n, rest'', hn, ⟨rfl, rfl⟩, rfl⟩ := h
  exact ⟨_, hs, _, hn⟩

/-- An event filtered out by `session_id` leaves the state untouched. -/
theorem prepare_none {state raw next : Term} {journal rest : List Term}
    (h : prepare state raw journal = .ok ((next, none), rest)) : next = state := by
  unfold prepare at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    or_false, pure_ok_iff, Prod.mk.injEq, reduceCtorEq, and_true] at h
  obtain ⟨-, -, normalized, rest', hs, -, hnext, -⟩ := h
  exact hnext

/-- The full event pipeline: schema admission, normalization and dispatch. -/
theorem prepare_extends {state raw next event : Term} {journal rest : List Term}
    (notMicrocompact : (event.get (b "type") == b "session_microcompact") = false)
    (notArchive : (event.get (b "type") == b "archive_advance") = false)
    (h : prepare state raw journal = .ok ((next, some event), rest)) : TranscriptExtends state next := by
  obtain ⟨_, _, _, hn⟩ := prepare_stringify h
  exact inner_extends notMicrocompact notArchive hn

/-- Closes a goal from `Term.tuple [Term.atom k, ..] = Term.tuple [Term.atom "done", ..]` with `k ≠ "done"`. -/
syntax "not_done" ident : tactic
macro_rules
  | `(tactic| not_done $h:ident) =>
    `(tactic| (injection $h with h₁; injection h₁ with h₂ h₃; injection h₂ with h₄; exact absurd h₄ (by decide)))

/-- `run` completing with `done` appends to the transcript or leaves it unchanged, for every
normalized event other than `archive_advance` and `session_microcompact`. -/
theorem run_done_extends {state raw next : Term} {journal : List Term}
    (kinds : ∀ event rest, shallowStringify raw journal = .ok (event, rest) →
      (event.get (b "type") == b "session_microcompact") = false ∧
        (event.get (b "type") == b "archive_advance") = false)
    (h : run state raw journal = .tuple [a "done", next]) : TranscriptExtends state next := by
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
    exact extends_refl _
  · not_done h
  · rename_i n normalized rest hp
    obtain ⟨rest', hs, _, hn⟩ := prepare_stringify hp
    have step : TranscriptExtends state n := inner_extends (kinds _ _ hs).1 (kinds _ _ hs).2 hn
    unfold runActivity at h
    split at h
    · rename_i d ha
      injection h with h₁
      injection h₁ with h₂ h₃
      injection h₃ with h₄
      subst h₄
      exact extends_trans step (afterEvent_extends ha)
    · not_done h
    · not_done h
    · not_done h
  · not_done h
  · not_done h

end VerifiedKernel.Session
