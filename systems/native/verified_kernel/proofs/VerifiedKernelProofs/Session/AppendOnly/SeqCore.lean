import VerifiedKernelProofs.Session.AppendOnly.Core

/-!
The `seq` invariant: every transcript message carries an integer `seq`, the stamps are
nondecreasing along the list, and none exceeds `last_seq`. This file defines the invariant,
the write lemmas that preserve it, and the walk tactic that proves preservation reducer by
reducer. `Sorted.lean` shows every dispatched event preserves it.
-/

namespace VerifiedKernel.Session
open Data

set_option maxHeartbeats 4000000
set_option Elab.async false

/-- The sequence watermark, as the reducers read it. -/
abbrev lastSeq (state : Term) : Term := (state.get (a "last_seq")).default (i 0)

/-- A message's stamp as an integer. -/
def seqOf (m : Term) : Int := integerValue (m.get (a "seq"))

/-- Transcript stamps are integers, nondecreasing along the list, and at most `last_seq`. -/
def SeqSorted (state : Term) : Prop :=
  ∃ (xs : List Term) (n : Int), state.get (a "messages") = .list xs ∧ lastSeq state = .integer n ∧
    (∀ m ∈ xs, ∃ k : Int, m.get (a "seq") = .integer k ∧ k ≤ n) ∧
    xs.Pairwise (fun m m' => seqOf m ≤ seqOf m')

/-- A state transition that preserves the invariant. -/
def SeqStep (s t : Term) : Prop := SeqSorted s → SeqSorted t

theorem seq_refl (s : Term) : SeqStep s s := id

theorem seq_trans {s x t : Term} (h₁ : SeqStep s x) (h₂ : SeqStep x t) : SeqStep s t := h₂ ∘ h₁

theorem seq_of_frame {s t : Term} (messages : t.get (a "messages") = s.get (a "messages"))
    (last : t.get (a "last_seq") = s.get (a "last_seq")) : SeqStep s t := by
  rintro ⟨xs, n, hm, hl, hs, hp⟩
  exact ⟨xs, n, by rw [messages, hm], by rw [lastSeq, last]; exact hl, hs, hp⟩

theorem default_integer (n : Int) (fallback : Term) : (Term.integer n).default fallback = .integer n := by
  simp [Term.default, Term.truthy]

/-! ### Key-generic write frames -/

theorem write_frame_key {s t : Term} {entries : List (String × Term)} {j r : List Term} (k : String)
    (h : write s entries j = .ok (t, r)) (ok : entries.all (fun e => e.1 != k) = true) :
    t.get (a k) = s.get (a k) := by
  induction entries generalizing s j with
  | nil =>
    unfold write at h
    simp only [List.foldlM_nil] at h
    obtain rfl := pure_ok h
    rfl
  | cons e rest ih =>
    obtain ⟨k', v⟩ := e
    simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at ok
    obtain ⟨j', h⟩ := write_cons h
    rw [ih h ok.2, get_put_other _ _ ok.1]

theorem write_get_key {s t v : Term} {entries : List (String × Term)} {j r : List Term} (k : String)
    (h : write s entries j = .ok (t, r))
    (ok : entries.reverse.find? (fun e => e.1 == k) = some (k, v)) : t.get (a k) = v := by
  induction entries generalizing s j with
  | nil => simp at ok
  | cons e rest ih =>
    obtain ⟨k', w⟩ := e
    obtain ⟨j', h⟩ := write_cons h
    rw [List.reverse_cons, List.find?_append] at ok
    cases hr : rest.reverse.find? (fun e => e.1 == k) with
    | some y =>
      rw [hr] at ok
      simp only [Option.some_or] at ok
      exact ih h (hr.trans ok)
    | none =>
      rw [hr] at ok
      simp only [Option.none_or, List.find?_cons, List.find?_nil] at ok
      split at ok
      · simp only [Option.some.injEq, Prod.mk.injEq] at ok
        obtain ⟨hk, rfl⟩ := ok
        have hk' := hk.symm
        subst hk'
        have frame : rest.all (fun e => e.1 != k) = true := by
          rw [List.find?_eq_none] at hr
          simp only [List.all_eq_true, bne_iff_ne, ne_eq]
          intro e he
          simpa using hr e (List.mem_reverse.mpr he)
        rw [write_frame_key k h frame, get_put_same]
      · exact absurd ok (by simp)

/-! ### Writes that preserve the invariant -/

theorem write_seq_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (ok : entries.all (fun e => e.1 != "messages" && e.1 != "last_seq") = true) : SeqStep s t := by
  have both : entries.all (fun e => e.1 != "messages") = true ∧ entries.all (fun e => e.1 != "last_seq") = true := by
    simp only [List.all_eq_true, Bool.and_eq_true] at ok ⊢
    exact ⟨fun e he => (ok e he).1, fun e he => (ok e he).2⟩
  exact seq_of_frame (write_frame_key _ h both.1) (write_frame_key _ h both.2)

/-- A write that only advances `last_seq` by one. -/
theorem write_seq_bump {s t v : Term} {entries : List (String × Term)} {j j' r r' : List Term}
    (hadd : add (lastSeq s) (i 1) j' = .ok (v, r')) (h : write s entries j = .ok (t, r))
    (ok : entries.all (fun e => e.1 != "messages") = true)
    (last : entries.reverse.find? (fun e => e.1 == "last_seq") = some ("last_seq", v)) : SeqStep s t := by
  rintro ⟨xs, n, hm, hl, hs, hp⟩
  rw [hl, add_integer] at hadd
  simp only [Except.ok.injEq, Prod.mk.injEq] at hadd
  obtain ⟨rfl, -⟩ := hadd
  refine ⟨xs, n + 1, by rw [write_frame_key _ h ok, hm], ?_, ?_, hp⟩
  · rw [lastSeq, write_get_key _ h last, default_integer]
  · intro m hm'
    obtain ⟨k, hk, hkn⟩ := hs m hm'
    exact ⟨k, hk, Int.le_trans hkn (Int.le_add_one (Int.le_refl n))⟩

/-- A write that appends one message stamped with the advanced `last_seq`. -/
theorem write_seq_append {s t v m : Term} {xs : List Term} {entries : List (String × Term)}
    {j j' r r' : List Term}
    (hadd : add (lastSeq s) (i 1) j' = .ok (v, r')) (read : s.get (a "messages") = .list xs)
    (h : write s entries j = .ok (t, r))
    (messages : entries.reverse.find? (fun e => e.1 == "messages") =
      some ("messages", .list (xs ++ [m.put (a "seq") v])))
    (last : entries.reverse.find? (fun e => e.1 == "last_seq") = some ("last_seq", v)) : SeqStep s t := by
  rintro ⟨xs', n, hm, hl, hs, hp⟩
  rw [read] at hm
  obtain rfl := Term.list.inj hm
  rw [hl, add_integer] at hadd
  simp only [Except.ok.injEq, Prod.mk.injEq] at hadd
  obtain ⟨rfl, -⟩ := hadd
  refine ⟨xs ++ [m.put (a "seq") (.integer (n + 1))], n + 1, write_get_key _ h messages, ?_, ?_, ?_⟩
  · rw [lastSeq, write_get_key _ h last, default_integer]
  · intro m' hm'
    rcases List.mem_append.mp hm' with hm' | hm'
    · obtain ⟨k, hk, hkn⟩ := hs m' hm'
      exact ⟨k, hk, Int.le_trans hkn (Int.le_add_one (Int.le_refl n))⟩
    · obtain rfl := List.mem_singleton.mp hm'
      exact ⟨n + 1, get_put_same _ _ _, Int.le_refl _⟩
  · rw [List.pairwise_append]
    refine ⟨hp, List.pairwise_singleton _ _, ?_⟩
    intro m₁ hm₁ m₂ hm₂
    obtain rfl := List.mem_singleton.mp hm₂
    obtain ⟨k, hk, hkn⟩ := hs m₁ hm₁
    simp only [seqOf, hk, get_put_same, integerValue]
    exact Int.le_trans hkn (Int.le_add_one (Int.le_refl n))

/-- What a successful `write` says about the invariant, for the three shapes the reducers use. -/
def WriteSeq (s : Term) (entries : List (String × Term)) (t : Term) : Prop :=
  (entries.all (fun e => e.1 != "messages" && e.1 != "last_seq") = true → SeqStep s t) ∧
  (∀ v : Term, (∃ j' r' : List Term, add (lastSeq s) (i 1) j' = .ok (v, r')) →
    entries.all (fun e => e.1 != "messages") = true →
    entries.reverse.find? (fun e => e.1 == "last_seq") = some ("last_seq", v) → SeqStep s t) ∧
  (∀ (xs : List Term) (v m : Term), (∃ j' r' : List Term, add (lastSeq s) (i 1) j' = .ok (v, r')) →
    s.get (a "messages") = .list xs →
    entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", .list (xs ++ [m.put (a "seq") v])) →
    entries.reverse.find? (fun e => e.1 == "last_seq") = some ("last_seq", v) → SeqStep s t)

theorem write_sstep {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧ WriteSeq s entries t :=
  step_iff fun h => ⟨write_seq_frame h, fun _ ⟨_, _, hadd⟩ ok last => write_seq_bump hadd h ok last,
    fun _ _ _ ⟨_, _, hadd⟩ read messages last => write_seq_append hadd read h messages last⟩

/-! ### Folds and filters -/

theorem foldlM_inv {α : Type} (P : α → Prop) {step : α → Term → KernelM α} {items : List Term}
    {init acc : α} {s r : List Term}
    (preserve : ∀ acc item s r acc', P acc → step acc item s = .ok (acc', r) → P acc')
    (start : P init) (h : List.foldlM step init items s = .ok (acc, r)) : P acc := by
  induction items generalizing init s with
  | nil =>
    simp only [List.foldlM_nil, pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
    exact start
  | cons item rest ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨acc', _, hstep, h⟩ := bind_ok h
    exact ih (preserve init item _ _ acc' start hstep) h

theorem filterAuxM_sublist (f : Term → KernelM Bool) (l acc : List Term) {s r res : List Term}
    (h : List.filterAuxM f l acc s = .ok (res, r)) :
    ∃ kept : List Term, res = kept.reverse ++ acc ∧ kept.Sublist l := by
  induction l generalizing acc s with
  | nil =>
    simp only [List.filterAuxM, pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨[], by simp [h.1], List.Sublist.refl _⟩
  | cons m rest ih =>
    simp only [List.filterAuxM] at h
    obtain ⟨b, _, _, h⟩ := bind_ok h
    cases b with
    | true =>
      obtain ⟨kept, hres, hsub⟩ := ih (acc := m :: acc) h
      exact ⟨m :: kept, by rw [hres]; simp, hsub.cons_cons m⟩
    | false =>
      obtain ⟨kept, hres, hsub⟩ := ih (acc := acc) h
      exact ⟨kept, hres, hsub.cons m⟩

theorem filterM_sublist (f : Term → KernelM Bool) (l : List Term) {s r res : List Term}
    (h : List.filterM f l s = .ok (res, r)) : res.Sublist l := by
  unfold List.filterM at h
  obtain ⟨_, _, haux, h⟩ := bind_ok h
  obtain ⟨kept, hres, hsub⟩ := filterAuxM_sublist f l [] haux
  simp only [pure_ok_iff, Prod.mk.injEq] at h
  rw [h.1, hres]
  simpa using hsub

/-- The invariant survives keeping a sublist of the transcript with `last_seq` unchanged. -/
theorem seq_of_sublist {s t : Term} {xs ys : List Term} (read : s.get (a "messages") = .list xs)
    (sub : ys.Sublist xs) (messages : t.get (a "messages") = .list ys)
    (last : t.get (a "last_seq") = s.get (a "last_seq")) : SeqStep s t := by
  rintro ⟨xs', n, hm, hl, hs, hp⟩
  rw [read] at hm
  obtain rfl := Term.list.inj hm
  exact ⟨ys, n, messages, by rw [lastSeq, last]; exact hl, fun m hm => hs m (sub.subset hm), hp.sublist sub⟩

/-- A map that keeps every `seq` stamp keeps the invariant with `last_seq` unchanged. -/
theorem seq_of_map {s t : Term} {xs ys : List Term} (read : s.get (a "messages") = .list xs)
    (stamps : ys.map (fun m => m.get (a "seq")) = xs.map (fun m => m.get (a "seq")))
    (messages : t.get (a "messages") = .list ys)
    (last : t.get (a "last_seq") = s.get (a "last_seq")) : SeqStep s t := by
  rintro ⟨xs', n, hm, hl, hs, hp⟩
  rw [read] at hm
  obtain rfl := Term.list.inj hm
  refine ⟨ys, n, messages, by rw [lastSeq, last]; exact hl, ?_, ?_⟩
  · intro m hm
    have : m.get (a "seq") ∈ xs.map (fun m => m.get (a "seq")) := by
      rw [← stamps]
      exact List.mem_map_of_mem hm
    obtain ⟨m', hm', heq⟩ := List.mem_map.mp this
    obtain ⟨k, hk, hkn⟩ := hs m' hm'
    exact ⟨k, by rw [← heq, hk], hkn⟩
  · have : List.Pairwise (fun v v' : Term => integerValue v ≤ integerValue v') (ys.map (fun m => m.get (a "seq"))) := by
      rw [stamps, List.pairwise_map]
      exact hp
    rw [List.pairwise_map] at this
    exact this

/-- Folding `f` and consing keeps `g` of the accumulator in step with the input. -/
theorem foldlM_cons_map {f : Term → KernelM Term} (g : Term → Term)
    (keep : ∀ x y s' r', f x s' = .ok (y, r') → g y = g x) (xs : List Term) {acc0 acc : List Term}
    {s r : List Term}
    (h : List.foldlM (fun acc item => (do return (← f item) :: acc : KernelM (List Term))) acc0 xs s = .ok (acc, r)) :
    acc.map g = (xs.map g).reverse ++ acc0.map g := by
  induction xs generalizing acc0 s with
  | nil =>
    simp only [List.foldlM_nil, pure_ok_iff, Prod.mk.injEq] at h
    rw [← h.1]
    simp
  | cons x rest ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨acc1, _, hstep, h⟩ := bind_ok h
    obtain ⟨y, _, hy, hstep⟩ := bind_ok hstep
    simp only [pure_ok_iff, Prod.mk.injEq] at hstep
    rw [hstep.1] at h
    rw [ih h]
    simp [keep x y _ _ hy]

/-- `enumMap` over a list with a stamp-preserving function preserves the stamps. -/
theorem enumMap_stamps {xs ys : List Term} {f : Term → KernelM Term} {s r : List Term}
    (keep : ∀ x y s' r', f x s' = .ok (y, r') → y.get (a "seq") = x.get (a "seq"))
    (h : enumMap (.list xs) f s = .ok (ys, r)) :
    ys.map (fun m => m.get (a "seq")) = xs.map (fun m => m.get (a "seq")) := by
  unfold enumMap at h
  obtain ⟨acc, _, hfold, h⟩ := bind_ok h
  simp only [pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨items, hitems, hxs⟩ := enumFold_ok hfold
  rw [hxs xs rfl] at hitems
  rw [h.1, List.map_reverse, foldlM_cons_map _ keep xs hitems]
  simp

/-! ### Walking a reducer for the invariant

Same shape as `transcript_walk`, with `SeqStep` goals and `<name>_seq` / `<name>_sstep` lemmas. -/

/-- Reducers that only appear once history events are included. -/
def historySteps : List Lean.Name := [`mergePredicate, `microcompactIds, `microcompact, `archiveAdvance]

syntax "sorted_step" ident : tactic
macro_rules
  | `(tactic| sorted_step $h:ident) =>
  `(tactic| first
      | (head_is $h [write]; simp only [write_sstep] at $h:ident; obtain ⟨_, frame, bump, append⟩ := $h
         first
           | refine seq_trans (frame rfl) ?_
           | (refine seq_trans (bump _ ?add rfl rfl) ?_; case add => assumption)
           | (refine seq_trans (append _ _ _ ?add ?read rfl rfl) ?_; (case add => assumption); (case read => assumption)))
      | (head_step $h "_sstep"; obtain ⟨_, stepped⟩ := $h; refine seq_trans stepped ?_))

syntax "sorted_walk" ident : tactic
macro_rules
  | `(tactic| sorted_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let hr := Lean.mkIdent `hr
  let staged := Lean.mkIdent `staged
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact seq_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (sorted_step $h; exact seq_refl _)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize Prod.fst _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h); head_is $hx [Pure.pure]
         simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
      | ((fail_if_success head_is $h [write]); (obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [field, fetch]; simp only [field, fetch_ok_iff] at $hx:ident
              obtain ⟨_, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Data.append]; simp only [append_ok_iff] at $hx:ident
              obtain ⟨_, _, $hl:ident, $hr:ident, $rfl:ident, _⟩ := $hx
              obtain $rfl:ident := Term.list.inj $hr)
           | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
           | (head_is $hx [Data.add]
              have added : ∃ j' r' : List Term, add _ (i 1) j' = .ok (_, r') := ⟨_, _, $hx⟩)
           | sorted_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | sorted_step $hx
               | ((repeat (fail_if_success sorted_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  sorted_step $hx)
               | skip)
           | (head_is $hx [write]; have $staged:ident : write _ _ _ = _ := $hx)
           | skip)
      | dsimp only at $h:ident)

end VerifiedKernel.Session
