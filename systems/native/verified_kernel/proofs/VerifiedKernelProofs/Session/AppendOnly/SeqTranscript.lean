import VerifiedKernelProofs.Session.AppendOnly.SeqBookkeeping

/-!
The `seq` invariant across the tool-result, assistant, log and seed events, and activity bookkeeping.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false


theorem transcriptToolResult_seq {s e t : Term} {j r : List Term}
    (h : transcriptToolResult s e j = .ok (t, r)) : SeqStep s t := by
  unfold transcriptToolResult at h
  sorted_walk h

theorem transcriptToolResult_sstep {s e t : Term} {j r : List Term} :
    transcriptToolResult s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptToolResult s e j ∧ SeqStep s t :=
  step_iff transcriptToolResult_seq

theorem transcriptAssistant_seq {s e t : Term} {j r : List Term}
    (h : transcriptAssistant s e j = .ok (t, r)) : SeqStep s t := by
  unfold transcriptAssistant at h
  sorted_walk h

theorem transcriptAssistant_sstep {s e t : Term} {j r : List Term} :
    transcriptAssistant s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptAssistant s e j ∧ SeqStep s t :=
  step_iff transcriptAssistant_seq

theorem transcriptLog_seq {s e t : Term} {j r : List Term} (h : transcriptLog s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold transcriptLog at h
  sorted_walk h

theorem transcriptLog_sstep {s e t : Term} {j r : List Term} :
    transcriptLog s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptLog s e j ∧ SeqStep s t :=
  step_iff transcriptLog_seq

/-- The fold that stamps seed entries: stamps stay above the old `last_seq`, at most the running
sequence, and decreasing along the (reversed) accumulator. -/
private def SeedAcc (n : Int) (acc : List Term × Term × Term × Bool × Term) : Prop :=
  ∃ m : Int, acc.2.2.2.2 = .integer m ∧ n ≤ m ∧
    (∀ x ∈ acc.1, ∃ k : Int, x.get (a "seq") = .integer k ∧ n < k ∧ k ≤ m) ∧
    acc.1.Pairwise (fun x y => seqOf y ≤ seqOf x)

theorem transcriptSeed_seq {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    SeqStep s t := by
  unfold transcriptSeed at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  try dsimp only at h
  obtain ⟨folded, _, hfold, h⟩ := bind_ok h
  obtain ⟨items, hitems, -⟩ := enumFold_ok hfold
  have foldInv := foldlM_inv (fun acc => ∀ n : Int, (s.get (a "last_seq")).default (i 0) = .integer n → SeedAcc n acc)
    ?preserve (fun n hn => ⟨n, hn, Int.le_refl n, by simp, List.Pairwise.nil⟩) hitems
  case preserve =>
    intro acc item s' r' acc' hP hstep n hn
    obtain ⟨ms, nx, sn, an, sq⟩ := acc
    obtain ⟨m, hm, hnm, hall, hpair⟩ := hP n hn
    simp only at hm
    subst hm
    dsimp only at hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
    split at hstep
    · simp only [pure_ok_iff, Prod.mk.injEq] at hstep
      obtain ⟨rfl, -⟩ := hstep
      exact ⟨m, rfl, hnm, hall, hpair⟩
    · obtain ⟨unstamped, _, _, hstep⟩ := bind_ok hstep
      obtain ⟨_, _, hadd, hstep⟩ := bind_ok hstep
      rw [add_integer] at hadd
      simp only [Except.ok.injEq, Prod.mk.injEq] at hadd
      obtain ⟨rfl, rfl⟩ := hadd
      try dsimp only at hstep
      obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
      obtain ⟨_, _, _, hstep⟩ := bind_ok hstep
      simp only [pure_ok_iff, Prod.mk.injEq] at hstep
      obtain ⟨rfl, -⟩ := hstep
      refine ⟨m + 1, rfl, Int.le_trans hnm (Int.le_add_one (Int.le_refl m)), ?_, ?_⟩
      · intro x hx
        rcases List.mem_cons.mp hx with rfl | hx
        · exact ⟨m + 1, get_put_same _ _ _, Int.lt_add_one_iff.mpr hnm, Int.le_refl _⟩
        · obtain ⟨k, hk, hnk, hkm⟩ := hall x hx
          exact ⟨k, hk, hnk, Int.le_trans hkm (Int.le_add_one (Int.le_refl m))⟩
      · rw [List.pairwise_cons]
        refine ⟨?_, hpair⟩
        intro y hy
        obtain ⟨k, hk, -, hkm⟩ := hall y hy
        simp only [seqOf, hk, get_put_same, integerValue]
        exact Int.le_trans hkm (Int.le_add_one (Int.le_refl m))
  clear hfold hitems
  obtain ⟨appended, nextId, dedupe, any, lastSeq⟩ := folded
  try dsimp only at h foldInv
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [field, fetch_ok_iff] at hx
  obtain ⟨_, _, rfl, _⟩ := hx
  obtain ⟨_, _, hx, h⟩ := bind_ok h
  simp only [append_ok_iff] at hx
  obtain ⟨_, _, hl, hr, rfl, _⟩ := hx
  obtain rfl := Term.list.inj hr
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals split at h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, _, h⟩ := bind_ok h
  all_goals obtain ⟨seeded, _, hw, h⟩ := bind_ok h
  all_goals obtain ⟨_, _, _, hfinal⟩ := bind_ok h
  all_goals
    rintro ⟨xs, n, hread, hlast, hstamped, hsorted⟩
    obtain ⟨m, hm, hnm, hall, hpair⟩ := foldInv n hlast
    try simp only at hm hall hpair
    subst hm
    rw [hread, default_list] at hl
    obtain rfl := Term.list.inj hl
    have hmessages := write_get_key "messages" hw rfl
    have hseq := write_get_key "last_seq" hw rfl
    have fm := write_frame_key "messages" hfinal rfl
    have fl := write_frame_key "last_seq" hfinal rfl
    refine ⟨_, m, by rw [fm, hmessages], ?_, ?_, ?_⟩
    · rw [lastSeq, fl, hseq, default_integer]
    · intro x hx
      rcases List.mem_append.mp hx with hx | hx
      · obtain ⟨k, hk, hkn⟩ := hstamped x hx
        exact ⟨k, hk, Int.le_trans hkn hnm⟩
      · obtain ⟨k, hk, -, hkm⟩ := hall x (List.mem_reverse.mp hx)
        exact ⟨k, hk, hkm⟩
    · rw [List.pairwise_append, List.pairwise_reverse]
      refine ⟨hsorted, hpair, ?_⟩
      intro x hx y hy
      obtain ⟨kx, hkx, hkn⟩ := hstamped x hx
      obtain ⟨ky, hky, hnk, -⟩ := hall y (List.mem_reverse.mp hy)
      simp only [seqOf, hkx, hky, integerValue]
      exact Int.le_of_lt (Int.lt_of_le_of_lt hkn hnk)

theorem transcriptSeed_sstep {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ SeqStep s t :=
  step_iff transcriptSeed_seq

theorem afterEvent_seq {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : SeqStep next t := by
  unfold afterEvent at h
  sorted_walk h

theorem afterEvent_sstep {previous next e t : Term} {j r : List Term} :
    afterEvent previous next e j = .ok (t, r) ↔ Except.ok (t, r) = afterEvent previous next e j ∧ SeqStep next t :=
  step_iff afterEvent_seq

end VerifiedKernel.Session
