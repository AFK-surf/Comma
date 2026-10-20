import VerifiedKernelProofs.Provider.Loop
import VerifiedKernelProofs.Provider.ProjectionStateless
import VerifiedKernelProofs.Provider.AnsweredCore
import VerifiedKernelProofs.Provider.MatchedCore

/-!
`syntheticRuntime` keeps the projection of a closed history as a prefix.

The loop of `syntheticRuntime` only prepends to its output accumulator. A runtime message that
arrives while a tool batch waits is queued, and the queue is empty whenever no call waits. So
after a history whose calls all have results, the output of the history is final, and later
messages only add to it.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- The loop state of `syntheticRuntime`: output (reversed), queued pairs, pending call ids,
claimed synthetic ids, the conversation-turn flag, and the synthetic-call flag. -/
abbrev SynState := List Term × List Term × List Term × Std.HashSet ByteArray × Bool × Bool

/-- A message that `syntheticRuntime` keeps in the leading context run. -/
def leadingRole (m : Term) : Bool :=
  member (openaiRole m) ["system", "summary", "runtime"]

/-- A message that `syntheticRuntime` turns into a synthetic call. -/
def runtimeBranch (r : Bool) (m : Term) : Bool :=
  member (openaiRole m) ["system", "summary", "runtime"] && (r || openaiRole m == b "runtime")

/-- The pending call ids after one message. -/
def pendingStep (r : Bool) (p : List Term) (m : Term) : List Term :=
  if runtimeBranch r m = true then p
  else if (openaiRole m == b "tool") = true then p.filter (· != callId m)
  else if (openaiRole m == b "assistant") = true then
    (items (Provider.field m "tool_calls")).map (callField · "id")
  else p

/-- The history after its leading context run, which the loop of `syntheticRuntime` reads. -/
def loopPart (xs : List Term) : List Term := xs.drop (xs.takeWhile leadingRole).length

theorem branch_inert {m : Term} {x : Bool}
    (h : (member (openaiRole m) ["system", "summary", "runtime"] && x) = true) : Inert m := by
  simp only [Bool.and_eq_true] at h
  obtain ⟨s, hs, eq⟩ := List.any_eq_true.mp h.1
  have role := text_beq_eq eq
  unfold Inert callsOf IsResult
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs
  rw [role]
  rcases hs with rfl | rfl | rfl <;> simp (config := {decide := true}) [text_beq_text]

theorem placeholderUser_inert : Inert placeholderUser := by
  refine ⟨?_, ?_⟩ <;> simp (config := {decide := true}) [callsOf, IsResult, openaiRole, placeholderUser,
    Provider.field, obj, text_beq_text]

theorem systemReply_inert : Inert systemReply := by
  refine ⟨?_, ?_⟩ <;> simp (config := {decide := true}) [callsOf, IsResult, openaiRole, systemReply,
    Provider.field, obj, items, text_beq_text]

theorem openStep_placeholderUser (st : List Term) : openStep st placeholderUser = st :=
  openStep_inert placeholderUser_inert st

theorem openStep_systemReply (st : List Term) : openStep st systemReply = st :=
  openStep_inert systemReply_inert st

/-- A queue that gains an inert message stays balanced. -/
theorem balanced_cons_inert {m : Term} {q : List Term} (hq : Balanced q.reverse) (hm : Inert m) :
    Balanced (m :: q).reverse := by
  rw [List.reverse_cons]
  exact Balanced.append hq (fun st => by simp [openStep_inert hm])

theorem Prepends.cons_cons {α : Type} (x y : α) (xs : List α) : Prepends (x :: y :: xs) xs := ⟨[x, y], rfl⟩

theorem Prepends.append_cons_cons {α : Type} (d : List α) (x y : α) (xs : List α) :
    Prepends (d ++ x :: y :: xs) xs := ⟨d ++ [x, y], by simp⟩

theorem Prepends.cons_append_cons {α : Type} (x : α) (d : List α) (y : α) (xs : List α) :
    Prepends (x :: (d ++ y :: xs)) xs := ⟨x :: d ++ [y], by simp⟩

/-- An element of a synthetic runtime call pair, or a placement turn. -/
def Synthetic (y : Term) : Prop :=
  (∃ m id reminder j ys k, runtimeCall m id reminder j = .ok (ys, k) ∧ y ∈ ys) ∨
    y = placeholderUser ∨ y = systemReply

/-- What one step of the `syntheticRuntime` loop guarantees. -/
structure SynStep (r : Bool) (m : Term) (s s' : SynState) : Prop where
  out : Prepends s'.1 s.1
  pending : s'.2.2.1 = pendingStep r s.2.2.1 m
  queued : (s.2.2.1 = [] → s.2.1 = []) → s'.2.2.1 = [] → s'.2.1 = []
  turn : s.2.2.2.2.1 = true → s'.2.2.2.2.1 = true
  user : runtimeBranch r m = false → (∀ j, conversationTurn m j = .ok (true, j)) → s'.2.2.2.2.1 = true
  source : ∀ y ∈ s'.1 ++ s'.2.1, y ∈ s.1 ++ s.2.1 ∨ y = m ∨ Synthetic y
  keep : runtimeBranch r m = false → (openaiRole m == b "tool" || openaiRole m != b "assistant") = true → m ∈ s'.1
  balQ : Balanced s.2.1.reverse → Balanced s'.2.1.reverse
  matched : Balanced s.2.1.reverse → ∀ st,
    (s'.1.reverse ++ s'.2.1.reverse).foldl openStep st = (s.1.reverse ++ s.2.1.reverse ++ [m]).foldl openStep st

/-! ### The leading run -/

theorem takeWhile_append_of_false {α : Type} {p : α → Bool} {xs ys : List α}
    (stop : ∃ x ∈ xs, p x = false) : (xs ++ ys).takeWhile p = xs.takeWhile p := by
  induction xs with
  | nil => simp at stop
  | cons x xs ih =>
    by_cases hx : p x = true
    · have : ∃ x ∈ xs, p x = false := by
        obtain ⟨y, hy, py⟩ := stop
        rcases List.mem_cons.mp hy with rfl | tail
        · simp [hx] at py
        · exact ⟨y, tail, py⟩
      simp [List.takeWhile_cons, hx, ih this]
    · simp [List.takeWhile_cons, hx]

theorem takeWhile_length_le {α : Type} (p : α → Bool) (xs : List α) : (xs.takeWhile p).length ≤ xs.length :=
  (List.takeWhile_sublist p).length_le

theorem loopPart_append {xs ys : List Term} (stop : ∃ x ∈ xs, leadingRole x = false) :
    loopPart (xs ++ ys) = loopPart xs ++ ys := by
  unfold loopPart
  rw [takeWhile_append_of_false stop, List.drop_append_of_le_length (takeWhile_length_le _ _)]

/-! ### One step -/

theorem pure_yield_ok {s s' : SynState} {j r : List Term}
    (h : (pure (ForInStep.yield s) : KernelM (ForInStep SynState)) j = .ok (.yield s', r)) : s' = s := by
  simp only [Session.pure_ok_iff, Prod.mk.injEq, ForInStep.yield.injEq] at h
  exact h.1

/-- Walks an execution hypothesis of a loop body to its `pure (.yield _)` leaves. -/
syntax "yield_walk" ident : tactic
macro_rules
  | `(tactic| yield_walk $h:ident) => `(tactic| repeat' first
      | (have leaf := pure_yield_ok $h; subst leaf)
      | (simp only [Session.fail_ok_iff] at $h:ident)
      | split at $h:ident
      | (obtain ⟨_, _, _, $h:ident⟩ := Session.bind_ok_iff.mp $h))

/-- Closes the `pending` field of a step: the branch conditions decide `pendingStep`. -/
syntax "syn_pending" : tactic
macro_rules
  | `(tactic| syn_pending) => `(tactic| (
      show _ = pendingStep _ _ _
      unfold pendingStep runtimeBranch
      repeat' split
      all_goals first | rfl | contradiction))

/-- Closes the `queued` field of a step: the queue empties whenever no call waits. -/
syntax "syn_queued" : tactic
macro_rules
  | `(tactic| syn_queued) => `(tactic| (
      intro hinv hp
      first
        | rfl
        | (dsimp only at hp ⊢; done)
        | (dsimp only at hp ⊢; exact hinv hp)
        | (dsimp only at hp ⊢; exfalso; exact ‹¬ List.isEmpty _ = true› (by rw [hp]; rfl))))

/-- Closes the `user` field of a step: a conversation turn outside the runtime branch sets the flag. -/
syntax "syn_user" : tactic
macro_rules
  | `(tactic| syn_user) => `(tactic| (
      intro (hrb : runtimeBranch _ _ = false) hct
      first
        | rfl
        | (exfalso
           unfold runtimeBranch at hrb
           exact absurd ‹(member (openaiRole _) ["system", "summary", "runtime"] && _) = true› (by simp [hrb]; done))
        | (exfalso
           have e := (hct _).symm.trans ‹conversationTurn _ _ = _›
           simp only [Except.ok.injEq, Prod.mk.injEq] at e
           exact absurd e.1.symm ‹_›)))

/-- Closes the `source` field of a step. -/
syntax "syn_source" : tactic
macro_rules
  | `(tactic| syn_source) => `(tactic| (
      intro y hy
      simp only [List.mem_append, List.mem_cons, List.mem_reverse] at hy ⊢
      first
        | (rcases hy with hy | hy <;> simp [hy])
        | grind [Synthetic]))

/-- Closes the `keep` field of a step. -/
syntax "syn_keep" : tactic
macro_rules
  | `(tactic| syn_keep) => `(tactic| (
      intro (hrb : runtimeBranch _ _ = false) hrole
      first
        | (simp; done)
        | (exfalso
           unfold runtimeBranch at hrb
           exact absurd ‹(member (openaiRole _) ["system", "summary", "runtime"] && _) = true› (by simp [hrb]; done))
        | (exfalso; simp_all)))

/-- Closes the `balQ` field of a step: queued pairs leave every waiting list unchanged. -/
syntax "syn_balq" : tactic
macro_rules
  | `(tactic| syn_balq) => `(tactic| (
      intro hq
      simp only [List.reverse_append, List.reverse_reverse, List.reverse_nil] at hq ⊢
      first
        | exact hq
        | exact Balanced.nil
        | exact Balanced.append hq (runtimeCall_balanced ‹runtimeCall _ _ _ _ = _›)
        | exact balanced_cons_inert hq (branch_inert ‹_›)
        | exact balanced_cons_inert (balanced_cons_inert hq systemReply_inert) (branch_inert ‹_›)))

/-- Closes the `matched` field of a step: balanced blocks and inert messages leave the waiting
calls unchanged, so moving queued pairs keeps the result. -/
syntax "syn_matched" : tactic
macro_rules
  | `(tactic| syn_matched) => `(tactic| (
      intro hq st
      have hq' : ∀ st, _ := hq
      try dsimp only
      simp only [List.reverse_cons, List.reverse_append, List.reverse_reverse, List.reverse_nil,
        List.append_assoc, List.singleton_append, List.nil_append, List.append_nil, List.cons_append,
        List.foldl_append, List.foldl_cons, List.foldl_nil, hq', openStep_placeholderUser,
        openStep_systemReply] at ⊢
      all_goals first
        | rfl
        | (have hw : ∀ st, _ := runtimeCall_balanced ‹runtimeCall _ _ _ _ = _›
           simp only [List.foldl_append, hw, hq', openStep_inert (branch_inert ‹_›)])
        | simp only [openStep_inert (branch_inert ‹_›)]
        | (have hq0 := ‹(_ : List Term) = [] → (_ : List Term) = []› (List.isEmpty_iff.mp ‹List.isEmpty _ = true›)
           simp only [hq0, List.reverse_nil, List.foldl_nil, List.nil_append, List.append_nil] at ⊢
           have hw : ∀ st, _ := runtimeCall_balanced ‹runtimeCall _ _ _ _ = _›
           simp only [List.foldl_append, hw, openStep_inert (branch_inert ‹_›)])))

/-- What the whole `syntheticRuntime` loop guarantees, from the guarantee of one step. -/
structure SynLoop (r : Bool) (xs : List Term) (s v : SynState) : Prop where
  out : Prepends v.1 s.1
  pending : v.2.2.1 = xs.foldl (pendingStep r) s.2.2.1
  queued : (s.2.2.1 = [] → s.2.1 = []) → v.2.2.1 = [] → v.2.1 = []
  turn : s.2.2.2.2.1 = true → v.2.2.2.2.1 = true

theorem synLoop {r : Bool} {f : Term → SynState → KernelM (ForInStep SynState)}
    (step : ∀ x b b' j k, f x b j = .ok (.yield b', k) → SynStep r x b b') (yields : Yields f)
    {xs : List Term} {s v : SynState} {j k : List Term} (h : ForIn.forIn xs s f j = .ok (v, k)) :
    SynLoop r xs s v where
  out := forIn_rel (R := fun s v : SynState => Prepends v.1 s.1) yields (fun _ => Prepends.refl _)
    (fun _ _ _ h₁ h₂ => Prepends.trans h₂ h₁) (fun x b b' j k hx => (step x b b' j k hx).out) h
  pending := forIn_fold (π := fun s : SynState => s.2.2.1) yields
    (fun x b b' j k hx => (step x b b' j k hx).pending) h
  queued := forIn_inv (I := fun s : SynState => s.2.2.1 = [] → s.2.1 = []) yields
    (fun x b b' j k hb hx => (step x b b' j k hx).queued hb) (b := s)
    |> fun inv hs => inv hs h
  turn := forIn_rel (R := fun s v : SynState => s.2.2.2.2.1 = true → v.2.2.2.2.1 = true) yields
    (fun _ h => h) (fun _ _ _ h₁ h₂ t => h₂ (h₁ t)) (fun x b b' j k hx => (step x b b' j k hx).turn) h

/-- Walks an execution hypothesis of a loop body and shows that it never stops the loop. -/
syntax "yields_walk" ident : tactic
macro_rules
  | `(tactic| yields_walk $h:ident) => `(tactic| repeat' first
      | (simp only [Session.pure_ok_iff, Prod.mk.injEq] at $h:ident; exact ⟨_, $h:ident.1⟩)
      | (simp only [Session.fail_ok_iff] at $h:ident)
      | split at $h:ident
      | (obtain ⟨_, _, _, $h:ident⟩ := Session.bind_ok_iff.mp $h))

/-- Proves `SynStep` for every run of the `syntheticRuntime` loop body. -/
syntax "syn_step" : tactic
macro_rules
  | `(tactic| syn_step) => `(tactic| (
      intro x b b' j r' hx
      yield_walk hx
      all_goals refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      all_goals try first
        | exact Prepends.refl _
        | exact Prepends.append _ _
        | exact Prepends.cons _ _
        | exact Prepends.append (_ :: _) _
        | exact Prepends.append_cons _ _ _
        | exact Prepends.cons_cons _ _ _
        | exact Prepends.append_cons_cons _ _ _ _
        | exact Prepends.cons_append_cons _ _ _ _
      all_goals try (syn_pending; done)
      all_goals try (syn_queued; done)
      all_goals try ((intro t; first | rfl | exact t); done)
      all_goals try (syn_user; done)
      all_goals try (syn_source; done)
      all_goals try (syn_keep; done)
      all_goals try (syn_balq; done)
      all_goals try (syn_matched; done)))

/-- Proves `Yields` for the `syntheticRuntime` loop body. -/
syntax "syn_yields" : tactic
macro_rules
  | `(tactic| syn_yields) => `(tactic| (intro x b j s r' hx; yields_walk hx))

theorem synLoop_user {r : Bool} {f : Term → SynState → KernelM (ForInStep SynState)}
    (step : ∀ x b b' j k, f x b j = .ok (.yield b', k) → SynStep r x b b') (yields : Yields f) :
    ∀ {xs : List Term} {s v : SynState} {j k : List Term},
      (∃ m ∈ xs, runtimeBranch r m = false ∧ ∀ j, conversationTurn m j = .ok (true, j)) →
      ForIn.forIn xs s f j = .ok (v, k) → v.2.2.2.2.1 = true
  | [], _, _, _, _, ⟨_, member, _⟩, _ => by simp at member
  | x :: xs, s, v, j, k, ⟨m, member, branch, turn⟩, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok yields h
    rcases List.mem_cons.mp member with rfl | tail
    · exact (synLoop step yields rest).turn ((step _ _ _ _ _ hx).user branch turn)
    · exact synLoop_user step yields ⟨m, tail, branch, turn⟩ rest

theorem mem_loopPart {m : Term} {xs : List Term} (member : m ∈ xs) (stop : leadingRole m = false) :
    m ∈ loopPart xs := by
  unfold loopPart
  induction xs with
  | nil => simp at member
  | cons x xs ih =>
    by_cases hx : leadingRole x = true
    · rcases List.mem_cons.mp member with rfl | tail
      · simp [stop] at hx
      · simpa [List.takeWhile_cons, hx] using ih tail
    · simpa [List.takeWhile_cons, hx] using member

/-- A conversation turn of the history: a user message or a tool result. -/
def TurnRole (m : Term) : Prop := openaiRole m = b "user" ∨ openaiRole m = b "tool"

theorem TurnRole.leading {m : Term} (h : TurnRole m) : leadingRole m = false := by
  unfold leadingRole; rcases h with h | h <;> rw [h] <;> rfl

theorem TurnRole.branch {m : Term} (r : Bool) (h : TurnRole m) : runtimeBranch r m = false := by
  unfold runtimeBranch; rcases h with h | h <;> rw [h] <;> rfl

theorem TurnRole.turn {m : Term} (h : TurnRole m) (j : List Term) : conversationTurn m j = .ok (true, j) := by
  unfold conversationTurn; rcases h with h | h <;> simp [h] <;> rfl

/-- The initial loop state of `syntheticRuntime xs`. -/
def synInit (xs : List Term) : SynState := ((xs.takeWhile leadingRole).reverse, [], [], ∅, false, false)

/-- The `syntheticRuntime` loop body, abstracted: its step guarantees, and that a loop run
whose turn flag is set is a run of `syntheticRuntime`. -/
structure SynModel (r sys : Bool) (f : Term → SynState → KernelM (ForInStep SynState)) : Prop where
  step : ∀ x b b' j k, f x b j = .ok (.yield b', k) → SynStep r x b b'
  yields : Yields f
  back : ∀ {xs : List Term} {j : List Term} {s : SynState} {j₁ : List Term},
    ForIn.forIn (loopPart xs) (synInit xs) f j = .ok (s, j₁) → s.2.2.2.2.1 = true →
    syntheticRuntime xs r sys j = .ok ((s.2.1 ++ s.1).reverse, j₁)

/-- A run of `syntheticRuntime` is its loop followed by the result. -/
theorem synModel_run {r sys : Bool} {xs : List Term} {j v k : List Term}
    (h : syntheticRuntime xs r sys j = .ok (v, k)) :
    ∃ f, SynModel r sys f ∧ ∃ s j₁, ForIn.forIn (loopPart xs) (synInit xs) f j = .ok (s, j₁) ∧
      (s.2.2.2.2.1 = true → v = (s.2.1 ++ s.1).reverse) := by
  unfold syntheticRuntime at h
  simp only [Session.bind_ok_iff] at h
  obtain ⟨s, j₁, hloop, h⟩ := h
  change (ForIn.forIn (m := KernelM) (loopPart xs) (synInit xs) _ : KernelM SynState) j = _ at hloop
  refine ⟨_, ⟨?step, ?yields, ?back⟩, s, j₁, hloop, fun turn => ?_⟩
  case back =>
    intro xs j s j₁ hloop turn
    unfold syntheticRuntime
    refine Session.bind_ok_iff.mpr ⟨s, j₁, hloop, ?_⟩
    simp only [turn, Bool.true_or, ↓reduceIte]
    rfl
  case step => syn_step
  case yields => syn_yields
  rw [turn] at h
  simp only [Bool.true_or, ↓reduceIte, Session.pure_ok_iff, Prod.mk.injEq] at h
  exact h.1

/-- The loop guarantees, including the conversation-turn flag. -/
theorem SynModel.loop {r sys : Bool} {f : Term → SynState → KernelM (ForInStep SynState)} (model : SynModel r sys f)
    {xs : List Term} {s v : SynState} {j k : List Term} (h : ForIn.forIn xs s f j = .ok (v, k)) :
    SynLoop r xs s v := synLoop model.step model.yields h

theorem SynModel.source {r sys : Bool} {f : Term → SynState → KernelM (ForInStep SynState)} (model : SynModel r sys f) :
    ∀ {xs : List Term} {s v : SynState} {j k : List Term}, ForIn.forIn xs s f j = .ok (v, k) →
      ∀ y ∈ v.1 ++ v.2.1, y ∈ s.1 ++ s.2.1 ∨ y ∈ xs ∨ Synthetic y
  | [], s, v, j, k, h => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    exact fun y hy => Or.inl hy
  | x :: xs, s, v, j, k, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok model.yields h
    intro y hy
    rcases model.source rest y hy with hy | hy | hy
    · rcases (model.step _ _ _ _ _ hx).source y hy with hy | rfl | hy
      · exact Or.inl hy
      · exact Or.inr (Or.inl (List.mem_cons_self ..))
      · exact Or.inr (Or.inr hy)
    · exact Or.inr (Or.inl (List.mem_cons_of_mem _ hy))
    · exact Or.inr (Or.inr hy)

theorem SynModel.keep {r sys : Bool} {f : Term → SynState → KernelM (ForInStep SynState)} (model : SynModel r sys f)
    {m : Term} (role : TurnRole m) :
    ∀ {xs : List Term} {s v : SynState} {j k : List Term}, m ∈ xs → ForIn.forIn xs s f j = .ok (v, k) → m ∈ v.1
  | [], _, _, _, _, member, _ => by simp at member
  | x :: xs, s, v, j, k, member, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok model.yields h
    rcases List.mem_cons.mp member with rfl | tail
    · have kept := (model.step _ _ _ _ _ hx).keep (role.branch r)
        (by rcases role with h | h <;> rw [h] <;> rfl)
      obtain ⟨d, hd⟩ := (model.loop rest).out
      rw [hd]
      exact List.mem_append_right _ kept
    · exact model.keep role tail rest

/-- `syntheticRuntime` of a closed history with a conversation turn is a prefix of
`syntheticRuntime` of every extension of that history. The history keeps its turn, and every
added message is an added input, a synthetic call, or a message of the history. -/
theorem syntheticRuntime_append {H E : List Term} {r sys : Bool} {v : List Term} {j k : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (closed : (loopPart H).foldl (pendingStep r) [] = [])
    (h : syntheticRuntime (H ++ E) r sys j = .ok (v, k)) :
    ∃ vH T jH, syntheticRuntime H r sys j = .ok (vH, jH) ∧ v = vH ++ T ∧ (∃ m ∈ vH, TurnRole m) ∧
      (∀ y ∈ T, y ∈ vH ∨ y ∈ E ∨ Synthetic y) ∧ (∀ y ∈ vH, y ∈ H ∨ Synthetic y) := by
  obtain ⟨m, member, role⟩ := turn
  have stop : ∃ x ∈ H, leadingRole x = false := ⟨m, member, role.leading⟩
  obtain ⟨f, model, s, j₁, hloop, result⟩ := synModel_run h
  have init : synInit (H ++ E) = synInit H := by unfold synInit; rw [takeWhile_append_of_false stop]
  rw [loopPart_append stop, init] at hloop
  obtain ⟨sH, jH, hH, hE⟩ := forIn_append_ok model.yields hloop
  have factsH := model.loop hH
  have factsE := model.loop hE
  have turnH := synLoop_user model.step model.yields
    ⟨m, mem_loopPart member role.leading, role.branch r, role.turn⟩ hH
  have queuedH : sH.2.1 = [] := factsH.queued (fun _ => rfl) (by rw [factsH.pending]; exact closed)
  obtain ⟨d, hd⟩ := factsE.out
  refine ⟨(sH.2.1 ++ sH.1).reverse, (s.2.1 ++ d).reverse, jH, model.back hH turnH, ?_,
    ⟨m, ?_, role⟩, ?_, ?_⟩
  · rw [result (factsE.turn turnH), hd, queuedH]
    simp
  · rw [queuedH]
    simpa using model.keep role (mem_loopPart member role.leading) hH
  · intro y hy
    have hy' : y ∈ s.1 ++ s.2.1 := by
      rw [hd]; simp only [List.mem_reverse, List.mem_append] at hy ⊢; rcases hy with hy | hy <;> simp [hy]
    rcases model.source hE y hy' with hy | hy | hy
    · exact Or.inl (by rw [queuedH] at hy ⊢; simpa using hy)
    · exact Or.inr (Or.inl hy)
    · exact Or.inr (Or.inr hy)

  · intro y hy
    have hy' : y ∈ sH.1 ++ sH.2.1 := by
      simp only [List.mem_reverse, List.mem_append] at hy ⊢; rcases hy with hy | hy <;> simp [hy]
    rcases model.source hH y hy' with hy | hy | hy
    · left
      unfold synInit at hy
      simp only [List.append_nil, List.mem_reverse] at hy
      exact (List.takeWhile_sublist _).subset hy
    · exact Or.inl ((List.drop_sublist _ _).subset hy)
    · exact Or.inr hy

/-- The loop keeps the waiting calls of its input: its output and queue wait for the calls that
the processed messages leave waiting. -/
theorem SynModel.matched {r sys : Bool} {f : Term → SynState → KernelM (ForInStep SynState)} (model : SynModel r sys f) :
    ∀ {xs : List Term} {s v : SynState} {j k : List Term}, ForIn.forIn xs s f j = .ok (v, k) →
      Balanced s.2.1.reverse → ∀ st,
      (v.1.reverse ++ v.2.1.reverse).foldl openStep st = (s.1.reverse ++ s.2.1.reverse ++ xs).foldl openStep st
  | [], s, v, j, k, h, _, st => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    simp
  | x :: xs, s, v, j, k, h, hq, st => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok model.yields h
    have step := model.step _ _ _ _ _ hx
    rw [model.matched rest (step.balQ hq) st, List.foldl_append, step.matched hq st, ← List.foldl_append]
    simp

/-- `syntheticRuntime` keeps a matched history matched. -/
theorem syntheticRuntime_matched {H v : List Term} {r sys : Bool} {j k : List Term}
    (turn : ∃ m ∈ H, TurnRole m) (matched : Matched H) (h : syntheticRuntime H r sys j = .ok (v, k)) :
    Matched v := by
  obtain ⟨m, member, role⟩ := turn
  obtain ⟨f, model, s, j₁, hloop, result⟩ := synModel_run h
  have turnH := synLoop_user model.step model.yields
    ⟨m, mem_loopPart member role.leading, role.branch r, role.turn⟩ hloop
  rw [result turnH]
  unfold Matched at matched ⊢
  have e := model.matched hloop (by unfold synInit; exact Balanced.nil) []
  rw [List.reverse_append, e]
  unfold synInit loopPart
  simp only [List.reverse_reverse, List.reverse_nil, List.append_nil]
  have split : H.takeWhile leadingRole ++ H.drop (H.takeWhile leadingRole).length = H := by
    conv => rhs; rw [← List.take_append_drop (H.takeWhile leadingRole).length H]
    rw [← List.prefix_iff_eq_take.mp (List.takeWhile_prefix leadingRole)]
  rw [split]
  exact matched

end VerifiedKernel.ProviderLoop
