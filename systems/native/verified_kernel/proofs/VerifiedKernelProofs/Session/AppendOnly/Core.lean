import VerifiedKernelProofs.Order
import VerifiedKernelProofs.Session.Kernel
import VerifiedKernelProofs.Proof.WalkTactic

/-!
Definitions, primitive lemmas and the walk tactics for the transcript proofs.
See `VerifiedKernel.Session.AppendOnly` for the theorems.
-/

namespace VerifiedKernel.Session
open Data

/- The walk below splits every branch of a reducer, so the larger reducers need more than
the default heartbeat budget. Asynchronous elaboration is off in these files so memory is
released between theorems under the 2 GiB build limit. No proof here uses `decide`,
`native_decide`, or `sorry`; `scripts/audit-axioms.lean` audits every declaration. -/
set_option maxHeartbeats 4000000
set_option Elab.async false

/-- `next` keeps every message of `state`, in order, as a prefix of its own transcript. -/
def TranscriptExtends (state next : Term) : Prop :=
  ∀ xs, state.get (a "messages") = .list xs → ∃ ys, next.get (a "messages") = .list (xs ++ ys)

theorem extends_refl (state : Term) : TranscriptExtends state state :=
  fun _ h => ⟨[], by simpa using h⟩

theorem extends_trans {s t u : Term} (h₁ : TranscriptExtends s t) (h₂ : TranscriptExtends t u) :
    TranscriptExtends s u := by
  intro xs hs
  obtain ⟨ys, hy⟩ := h₁ xs hs
  obtain ⟨zs, hz⟩ := h₂ _ hy
  exact ⟨ys ++ zs, by simpa using hz⟩

theorem extends_of_frame {s t : Term} (h : t.get (a "messages") = s.get (a "messages")) :
    TranscriptExtends s t :=
  fun _ hs => ⟨[], by simpa [h] using hs⟩

/-! ### Monad and data primitives -/

theorem bind_ok {α β : Type} {m : KernelM α} {k : α → KernelM β} {s : List Term} {r : β × List Term}
    (h : (m >>= k) s = .ok r) : ∃ x s', m s = .ok (x, s') ∧ k x s' = .ok r := by
  simp only [Bind.bind, StateT.bind] at h
  cases hm : m s with
  | error e => simp [hm, Except.bind] at h
  | ok p =>
    obtain ⟨x, s'⟩ := p
    exact ⟨x, s', rfl, by simpa [hm, Except.bind] using h⟩

theorem pure_ok {α : Type} {x y : α} {s r : List Term} (h : (pure x : KernelM α) s = .ok (y, r)) :
    y = x := by
  simp [Pure.pure, StateT.pure, Except.pure] at h
  exact h.1.symm

theorem fail_ok {α : Type} {kind : String} {args : List Term} {s : List Term} {r : α × List Term}
    (h : (fail kind args : KernelM α) s = .ok r) : False := by
  simp [fail, throw, throwThe, MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at h

theorem atom_beq_true {t : Term} {k : String} (h : (t == Term.atom k) = true) : t = Term.atom k := by
  cases t <;> simp [BEq.beq] at h
  subst h; rfl

theorem atom_beq_self (k : String) : (Term.atom k == Term.atom k) = true := by
  simp [BEq.beq]

theorem atom_beq_ne {k l : String} (h : k ≠ l) : (Term.atom k == Term.atom l) = false := by
  simp [BEq.beq, h]

theorem find?_filter_of_imp {α : Type} (p q : α → Bool) (l : List α)
    (imp : ∀ x, p x = true → q x = true) : List.find? p (l.filter q) = List.find? p l := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases hp : p x = true
    · have hq := imp x hp
      simp [hq, hp]
    · have hp' : p x = false := by simpa using hp
      cases hq : q x <;> simp [hq, hp', ih]

theorem get_put_same (v x : Term) (k : String) : (Term.put v (Term.atom k) x).get (Term.atom k) = x := by
  cases v <;> simp [Term.put, Term.get, atom_beq_self]

theorem get_put_other (v x : Term) {k l : String} (h : l ≠ k) :
    (Term.put v (Term.atom l) x).get (Term.atom k) = v.get (Term.atom k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, atom_beq_ne h]
    rw [find?_filter_of_imp]
    intro e he
    have := atom_beq_true he
    simp [this, atom_beq_ne (Ne.symm h)]
  | _ => simp [Term.put, Term.get, atom_beq_ne h]

theorem put_ok {v key x y : Term} {s r : List Term} (h : Data.put v key x s = .ok (y, r)) :
    y = Term.put v key x := by
  unfold Data.put at h
  split at h
  · exact pure_ok h
  · exact (fail_ok h).elim

theorem default_list (xs : List Term) (fallback : Term) : (Term.list xs).default fallback = .list xs := by
  simp [Term.default, Term.truthy]

/-! ### Syntactic forms for the walk

`simp only` matches these left-hand sides structurally, so the walk never unfolds a
reducer to look for a bind, a `pure`, or a failure inside it. -/

theorem bind_ok_iff {α β : Type} {m : KernelM α} {k : α → KernelM β} {s : List Term} {r : β × List Term} :
    (m >>= k) s = .ok r ↔ ∃ x s', m s = .ok (x, s') ∧ k x s' = .ok r := by
  constructor
  · exact bind_ok
  · rintro ⟨x, s', hm, hk⟩
    simp [Bind.bind, StateT.bind, hm, Except.bind, hk]

theorem pure_ok_iff {α : Type} {x : α} {s : List Term} {r : α × List Term} :
    (pure x : KernelM α) s = .ok r ↔ r = (x, s) := by
  constructor
  · intro h
    simp [Pure.pure, StateT.pure, Except.pure] at h
    exact h.symm
  · rintro rfl
    rfl

theorem ite_ok_iff {α : Type} {c : Prop} [Decidable c] {A B : KernelM α} {s : List Term} {r : α × List Term} :
    (if c then A else B) s = .ok r ↔ (c ∧ A s = .ok r) ∨ (¬c ∧ B s = .ok r) := by
  split <;> simp [*]

theorem fail_ok_iff {α : Type} {kind : String} {args : List Term} {s : List Term} {r : α × List Term} :
    (fail kind args : KernelM α) s = .ok r ↔ False :=
  ⟨fail_ok, False.elim⟩

theorem fetch_ok_iff {v key x : Term} {s r : List Term} :
    fetch v key s = .ok (x, r) ↔ v.isMap = true ∧ v.has key = true ∧ x = v.get key ∧ r = s := by
  unfold fetch
  split
  · simp_all [fail_ok_iff]
  · split
    · simp_all [pure_ok_iff]
    · simp_all [fail_ok_iff]

theorem asList_ok_iff {v : Term} {xs : List Term} {s r : List Term} :
    asList v s = .ok (xs, r) ↔ v = .list xs ∧ r = s := by
  unfold asList
  split
  · simp only [pure_ok_iff, Prod.mk.injEq, Term.list.injEq]
    constructor
    · rintro ⟨rfl, rfl⟩; exact ⟨rfl, rfl⟩
    · rintro ⟨rfl, rfl⟩; exact ⟨rfl, rfl⟩
  · simp_all [fail_ok_iff]

theorem append_ok_iff {l r x : Term} {s t : List Term} :
    Data.append l r s = .ok (x, t) ↔ ∃ xs ys, l = .list xs ∧ r = .list ys ∧ x = .list (xs ++ ys) ∧ t = s := by
  unfold Data.append
  simp only [bind_ok_iff, asList_ok_iff, pure_ok_iff]
  constructor
  · rintro ⟨xs, s1, ⟨rfl, rfl⟩, ys, s2, ⟨rfl, rfl⟩, h⟩
    simp only [Prod.mk.injEq] at h
    exact ⟨xs, ys, rfl, rfl, h.1, h.2⟩
  · rintro ⟨xs, ys, rfl, rfl, rfl, rfl⟩
    exact ⟨xs, _, ⟨rfl, rfl⟩, ys, _, ⟨rfl, rfl⟩, rfl⟩

/-! ### `write` frame lemmas -/

theorem write_cons {s t : Term} {k : String} {v : Term} {rest : List (String × Term)} {j r : List Term}
    (h : write s ((k, v) :: rest) j = .ok (t, r)) :
    ∃ j', write (Term.put s (Term.atom k) v) rest j' = .ok (t, r) := by
  unfold write at h ⊢
  rw [List.foldlM_cons] at h
  obtain ⟨x, j', hx, h⟩ := bind_ok h
  obtain ⟨_, _, _, hx⟩ := bind_ok hx
  obtain rfl := put_ok hx
  exact ⟨j', h⟩

theorem write_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r)) (ok : entries.all (fun e => e.1 != "messages") = true) :
    t.get (a "messages") = s.get (a "messages") := by
  induction entries generalizing s j with
  | nil =>
    unfold write at h
    simp only [List.foldlM_nil] at h
    obtain rfl := pure_ok h
    rfl
  | cons e rest ih =>
    obtain ⟨k, v⟩ := e
    simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at ok
    obtain ⟨j', h⟩ := write_cons h
    rw [ih h ok.2, get_put_other _ _ ok.1]

theorem write_get {s t v : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (ok : entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", v)) :
    t.get (a "messages") = v := by
  induction entries generalizing s j with
  | nil => simp at ok
  | cons e rest ih =>
    obtain ⟨k, w⟩ := e
    obtain ⟨j', h⟩ := write_cons h
    rw [List.reverse_cons, List.find?_append] at ok
    cases hr : rest.reverse.find? (fun e => e.1 == "messages") with
    | some y =>
      rw [hr] at ok
      simp only [Option.some_or] at ok
      exact ih h (hr.trans ok)
    | none =>
      rw [hr] at ok
      simp only [Option.none_or, List.find?_cons, List.find?_nil] at ok
      split at ok
      · simp only [Option.some.injEq, Prod.mk.injEq] at ok
        obtain ⟨rfl, rfl⟩ := ok
        have frame : rest.all (fun e => e.1 != "messages") = true := by
          rw [List.find?_eq_none] at hr
          simp only [List.all_eq_true, bne_iff_ne, ne_eq]
          intro e he
          simpa using hr e (List.mem_reverse.mpr he)
        rw [write_frame h frame, get_put_same]
      · exact absurd ok (by simp)

theorem write_extends {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r)) (ok : entries.all (fun e => e.1 != "messages") = true) :
    TranscriptExtends s t :=
  extends_of_frame (write_frame h ok)

/-- A write whose `messages` entry appends to the list that was read from the state. -/
theorem write_append_extends {s t v : Term} {entries : List (String × Term)} {xs ys : List Term}
    {j r : List Term} (h : write s entries j = .ok (t, r))
    (read : s.get (a "messages") = .list xs)
    (ok : entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", v))
    (value : v = .list (xs ++ ys)) : TranscriptExtends s t := by
  intro zs hz
  rw [read] at hz
  obtain rfl := Term.list.inj hz
  exact ⟨ys, by rw [write_get h ok, value]⟩

/-- The seed path reads the list through `default`, which is the identity on lists. -/
theorem write_seed_extends {s t v : Term} {entries : List (String × Term)} {xs ys : List Term}
    {j r : List Term} (h : write s entries j = .ok (t, r))
    (read : (s.get (a "messages")).default (list []) = .list xs)
    (ok : entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", v))
    (value : v = .list (xs ++ ys)) : TranscriptExtends s t := by
  intro zs hz
  rw [hz, default_list] at read
  obtain rfl := Term.list.inj read
  exact ⟨ys, by rw [write_get h ok, value]⟩

/-! ### Step lemmas

`simp only [<name>_step] at h` matches the head symbol of `h` structurally. The rewritten
equation is flipped so simp does not loop, and the extension fact rides along. -/

theorem step_iff {α : Type} {x y : α} {q : Prop} (h : x = y → q) : x = y ↔ y = x ∧ q :=
  ⟨fun e => ⟨e.symm, h e⟩, fun ⟨e, _⟩ => e.symm⟩

/-- What a successful `write` says about the transcript, for the three shapes the reducers use. -/
def WriteStep (s : Term) (entries : List (String × Term)) (t : Term) : Prop :=
  (entries.all (fun e => e.1 != "messages") = true → TranscriptExtends s t) ∧
  (∀ (xs ys : List Term) (v : Term), s.get (a "messages") = .list xs →
    entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", v) →
    v = .list (xs ++ ys) → TranscriptExtends s t) ∧
  (∀ (xs ys : List Term) (v : Term), (s.get (a "messages")).default (list []) = .list xs →
    entries.reverse.find? (fun e => e.1 == "messages") = some ("messages", v) →
    v = .list (xs ++ ys) → TranscriptExtends s t)

theorem write_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧ WriteStep s entries t :=
  step_iff fun h => ⟨write_extends h, fun _ _ _ read ok value => write_append_extends h read ok value,
    fun _ _ _ read ok value => write_seed_extends h read ok value⟩

/-! ### Walking a reducer

`transcript_step h` consumes one state-transforming call `h : f s .. j = .ok (t, r)` and advances
the goal `TranscriptExtends s u` to `TranscriptExtends t u`. The lemma `f_step` is selected by the
head constant of `h` (`head_step`), so no other reducer lemma is tried and unification never
unfolds two different reducers against each other.

`transcript_walk h` repeats the following until nothing applies: flatten binds and branches into
existentials and disjunctions, destructure them, substitute reads, step state transformers,
split matches, and close `pure` and failure leaves. Reads that do not return a state leave the
goal unchanged. -/

/-- The state transformers a reducer can call. Each has a lemma `<name>_extends` below. -/
def transcriptSteps : List Lean.Name :=
  [`bumpHwm, `appendFields, `appendMessage, `noteResult, `noteAsyncResult, `asyncStart, `asyncTerminal,
   `resetFresh, `addObligation, `obligationResolve, `obligationCard, `replyRepair, `replyIntent,
   `retireIntent, `activationStarted, `activationFinished, `sessionAck, `waitClear, `pruneResultRefs,
   `queueAppend, `queueAck, `queueConsume, `statusTransition, `activityTransition, `metadataCreated,
   `metadataPrompt, `metadataUpdate, `compactionFailure, `compactionRecovery, `sessionEvent,
   `progressStep, `pruneCompactResults, `recomputeContext, `historyCompaction, `compactResult,
   `storedResult, `transcriptToolResult, `transcriptAssistant, `transcriptLog, `transcriptSeed,
   `runtimeAppend, `transcriptRuntime, `transcriptDelivery, `afterEvent, `stampWorkReasons,
   `stampAgentId, `stampRuntimeEpoch, `stampRuntimeNode, `stampActivityRevision, `stampStorageRevision, `stampFlushId, `stampWorkIndexToken,
   `sessionStamp, `bumpHwmEvent]

syntax "transcript_step" ident : tactic
macro_rules
  | `(tactic| transcript_step $h:ident) =>
  `(tactic| first
      | (head_is $h [write]; simp only [write_step] at $h:ident; obtain ⟨_, frame, append, seed⟩ := $h
         first
           | refine extends_trans (frame rfl) ?_
           | (refine extends_trans (append _ _ _ ?read rfl rfl) ?_; case read => assumption)
           | (refine extends_trans (seed _ _ _ ?read rfl rfl) ?_; case read => assumption))
      | (head_step $h "_step"; obtain ⟨_, stepped⟩ := $h; refine extends_trans stepped ?_))

syntax "transcript_walk" ident : tactic
macro_rules
  | `(tactic| transcript_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact extends_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (transcript_step $h; exact extends_refl _)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [field, fetch]; simp only [field, fetch_ok_iff] at $hx:ident
              obtain ⟨_, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Data.append]; simp only [append_ok_iff] at $hx:ident
              obtain ⟨_, _, $hl:ident, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
           | transcript_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | transcript_step $hx
               | ((repeat (fail_if_success transcript_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  transcript_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

set_option backward.split false in
/-- The Session operations of `runtimeAppend`, in order. The other binds only read the Session
or the event. A frame proof composes these four steps. This is much cheaper than a walk over
every branch of `runtimeAppend`. -/
theorem runtimeAppend_ops {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    ∃ message dedupe wait hwm appended updated bumped : Term, ∃ j₁ j₂ j₃ j₄ r₁ r₂ r₃ : List Term,
      appendFields s e message j₁ = .ok (appended, r₁) ∧
      write appended [("input_dedupe", dedupe), ("wait", wait)] j₂ = .ok (updated, r₂) ∧
      bumpHwm updated hwm j₃ = .ok (bumped, r₃) ∧
      resetFresh bumped message j₄ = .ok (t, r) := by
  unfold runtimeAppend at h
  repeat' first
    | exact (fail_ok h).elim
    | (head_is h [resetFresh]
       exact ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appendedCall, writtenCall, bumpedCall, h⟩)
    | (head_is h [Bind.bind]
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | exact (fail_ok prior).elim
         | (head_is prior [Pure.pure]; have same := pure_ok prior; subst value)
         | (head_is prior [appendFields]; have appendedCall := prior)
         | (head_is prior [write]; have writtenCall := prior)
         | (head_is prior [bumpHwm]; have bumpedCall := prior)
         | skip)
    | dsimp only at h
    | split at h

set_option backward.split false in
/-- The Session operations of `transcriptDelivery`, in order. A delivery that is not from the
queue returns the Session unchanged. The other binds only read the Session or the event. A frame
proof composes these steps. This is much cheaper than a walk over every branch of
`transcriptDelivery`. -/
theorem transcriptDelivery_ops {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) :
    t = s ∨ ∃ message billing dedupe wait repair raw hwm appended updated obligated bumped : Term,
      ∃ j₁ j₂ j₃ j₄ j₅ r₁ r₂ r₃ r₄ : List Term,
      appendFields s e message j₁ = .ok (appended, r₁) ∧
      write appended [("billing_context", billing), ("input_dedupe", dedupe), ("wait", wait),
        ("visible_reply_repair", repair)] j₂ = .ok (updated, r₂) ∧
      addObligation updated raw j₃ = .ok (obligated, r₃) ∧
      bumpHwm obligated hwm j₄ = .ok (bumped, r₄) ∧
      resetFresh bumped message j₅ = .ok (t, r) := by
  unfold transcriptDelivery at h
  repeat' first
    | exact (fail_ok h).elim
    | (head_is h [Pure.pure]; exact Or.inl (pure_ok h))
    | (head_is h [resetFresh]
       exact Or.inr ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _,
         appendedCall, writtenCall, obligatedCall, bumpedCall, h⟩)
    | (head_is h [Bind.bind]
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | exact (fail_ok prior).elim
         | (head_is prior [Pure.pure]; have same := pure_ok prior; subst value)
         | (head_is prior [appendFields]; have appendedCall := prior)
         | (head_is prior [write]; have writtenCall := prior)
         | (head_is prior [addObligation]; have obligatedCall := prior)
         | (head_is prior [bumpHwm]; have bumpedCall := prior)
         | skip)
    | dsimp only at h
    | split at h
    | (generalize Term.get _ _ = discriminant at h; split at h)

end VerifiedKernel.Session
