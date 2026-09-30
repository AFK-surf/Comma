import VerifiedKernelProofs.Loop.Budget
import VerifiedKernelProofs.Loop.RoundFrames
import VerifiedKernelProofs.Loop.Host

/-! # Activation chains on the host model (property C, internal work)

An activation chain is a sequence of internal loop steps in the activation
phases (`activation`, `router`, `busy`, `timeout`). The host answers each
internal effect at once. This module bounds the number of kernel steps in such
a chain on the host model of `Host.lean`. The bound is linear in the
environment writes that happen during the chain, and in no other count.

* `activation_chain_bounded`, `activation_chain_after`: a chain runs at most
  `chainBound C · (1 + e)` kernel steps, where `e` counts the `env` labels of
  the chain and `C` bounds the ceiling fact of the entry.
  `chainBound C = 8 · (C / 1000) + 26`. Hypothesis: the host answers the
  Router fact with a present value (`RouterFactsPresent`).
* `model_chain_bounded`: a chain in the model-round phases has at most 4
  steps, for any oracle. These phases have no re-entry.

The proof uses a potential (`chainPot`): the phase rank, one unit for a
possible yield (the working state has a wait), the extensions that the wait
still allows, one unit for a possible changed wait, and a large weight when
another writer changed the durable state since the host last read it. Each
kernel step lowers the potential (`chain_step`):

* `act_step`: an internal step drops the phase rank, or it is a provider-wait
  yield, a wait extension, or a changed wait.
* A yield writes the answer of `provider_wait_yield_events`. After it applies,
  the session has no wait (`RoundFrames.yield_clears_wait_of`), so the yield
  unit is spent.
* An extension commits a wait with at least one more second of
  `extended_ms`, within the ceiling (`WaitBudget.wait_extension_budget`).
* A changed wait needs a wait that differs from the wait that the busy request
  read. On the host model only a read of a durable state that another writer
  changed can cause this.
-/

namespace VerifiedKernel.Session.Loop.Budget
open Data
open VerifiedKernel.Session.LoopProof
open VerifiedKernel.Session.WorkConservation
open VerifiedKernel.Session.Loop.RoundFrames
set_option Elab.async false
set_option maxHeartbeats 1000000

/-! ## Activation outputs -/

/-- No effect is a `write` or a `commit`. -/
def Plain (effs : List Term) : Prop := ∀ e ∈ effs, effectKind e ≠ .write ∧ effectKind e ≠ .commit

/-- The internal outputs of `activation` for a machine `m`. -/
def ActivationOut (ask : Loop.Ask) (state m : Term) (out : Term) : Prop :=
  Internal out →
    fact (outMachine out) "ceiling_ms" = fact m "ceiling_ms" ∧
    ((mkey (outMachine out) "phase" = b "router" ∧
        Returns (ask state "activation_next" (mkey m "router")) (a "check_router") ∧
        outEffects out = [.tuple [a "fact", a "canonical_router"]]) ∨
     (mkey (outMachine out) "phase" = b "busy" ∧ mkey (outMachine out) "expected" = state.get (a "wait") ∧
        Plain (outEffects out)) ∨
     (mkey (outMachine out) "phase" = b "activation" ∧
        Returns (ask state "activation_next" (mkey m "router")) (a "yield") ∧
        ∃ es expected j j', ask state "provider_wait_yield_events" expected j = .ok (list es, j') ∧
          es ≠ [] ∧ outEffects out = [.tuple [a "write", list es], a "continue"]))

theorem fact_put_ne (m v : Term) {k : String} (h : k ≠ "round") (name : String) :
    fact (m.put (b k) v) name = fact m name := by
  unfold fact
  rw [mkey_put_ne m v h]

theorem asList_list {v : Term} {xs j j' : List Term} (h : asList v j = .ok (xs, j')) : v = list xs := by
  exact (asList_ok_iff.mp h).1

theorem plain_fetch (name : Term) : Plain [.tuple [a "fact", name]] := by
  intro e mem
  simp only [List.mem_singleton] at mem
  subst mem
  simp [effectKind]

/-- An expiry entry is internal only when it asks for the busy fact. Its
machine records the wait that it read. -/
def EntryAct (state m : Term) (out : Term) : Prop :=
  Internal out →
    fact (outMachine out) "ceiling_ms" = fact m "ceiling_ms" ∧ mkey (outMachine out) "phase" = b "busy" ∧
      mkey (outMachine out) "expected" = state.get (a "wait") ∧ Plain (outEffects out)

theorem expireEntry_act {state m : Term} : Sat (EntryAct state m) (expireEntryN state m) := by
  unfold expireEntryN
  unfold_native "VerifiedKernel.Session.Loop.expireEntry"
  sat_walk
  · loop_unfold
    intro _
    have hw := RoundFrames.field_value ‹field state "wait" _ = _›
    refine ⟨?_, mkey_put_phase _ _, ?_, plain_fetch _⟩
    · simp only [outMachine_tuple]
      rw [fact_put_ne _ _ (by decide), fact_put_ne _ _ (by decide)]
    · simp only [outMachine_tuple]
      rw [mkey_put_ne _ _ (by decide), mkey_put_same, hw]
  · rename_i w0 j0 j0' read0 _
    intro j out j' run
    intro internal
    rcases Sat.use expire_out run internal with ⟨_, w, ⟨_, _, read⟩, changed⟩ | ⟨_, _, _, _, _, decided, _⟩
    · exfalso
      have same := field_det read read0
      subst same
      simp [mkey, put_isMap, get_put_same_binary, bne, term_beq_self] at changed
    · exact (not_extend_idle decided).elim

theorem activation_act {ask : Loop.Ask} {state m : Term} :
    Sat (ActivationOut ask state m) (activationN ask state m) := by
  unfold activationN
  unfold_native "VerifiedKernel.Session.Loop.activation"
  sat_walk
  all_goals first
    | exact (fail_ok ‹_›).elim
    | (loop_unfold
       intro _
       refine ⟨?_, Or.inl ⟨mkey_put_phase _ _, ?_, rfl⟩⟩
       · simp only [outMachine_tuple]
         rw [fact_put_ne _ _ (by decide), fact_put_ne _ _ (by decide)]
       · rw [← mkey_put_ne m (b "activation") (show "phase" ≠ "router" by decide)]
         exact ⟨_, _, ‹_›⟩)
    | (loop_unfold
       intro _
       obtain rfl := asList_list ‹asList _ _ = _›
       refine ⟨?_, Or.inr (Or.inr ⟨mkey_put_phase _ _, ?_, _, _, _, _,
         ‹ask state "provider_wait_yield_events" _ _ = _›, ?_, rfl⟩)⟩
       · simp only [outMachine_tuple]
         rw [fact_put_ne _ _ (by decide)]
       · rw [← mkey_put_ne m (b "activation") (show "phase" ≠ "router" by decide)]
         exact ⟨_, _, ‹_›⟩
       · intro empty
         subst empty
         exact ‹¬ _ = true› rfl)
    | (loop_unfold
       refine Sat.mono expireEntry_act (fun out entry internal => ?_)
       obtain ⟨ceiling, busy, expected, plain⟩ := entry internal
       refine ⟨?_, Or.inr (Or.inl ⟨busy, expected, plain⟩)⟩
       rw [ceiling, fact_put_ne _ _ (by decide)])
    | (unfold ActivationOut; loop_unfold; simp [Internal])

/-- The `wait_set` event of an extension. -/
def waitSetFor (state next : Term) : Term :=
  .map [(b "type", b "wait_set"), (b "session_id", state.get (a "session_id")), (b "wait", next)]

theorem waitSetEvent_eq {state next event : Term} {j j' : List Term}
    (h : waitSetEventN state next j = .ok (event, j')) : event = waitSetFor state next := by
  revert h
  unfold waitSetEventN
  unfold_native "VerifiedKernel.Session.Loop.waitSetEvent"
  intro h
  obtain ⟨sid, _, read, rest⟩ := bind_ok h
  rw [pure_ok rest, RoundFrames.field_value read]
  rfl

/-- The phase of an expiry re-entry: `timeout` for a fired timer, else `activation`. -/
theorem entry_phase (m : Term) (timer : Bool) :
    mkey (m.put (b "phase") (b (if timer then "timeout" else "activation"))) "phase" = b "timeout" ∨
      mkey (m.put (b "phase") (b (if timer then "timeout" else "activation"))) "phase" = b "activation" := by
  rw [mkey_put_phase]
  cases timer <;> simp

/-- The internal outputs of `expire`: a changed wait with exactly `continue`,
or an extension that commits the extended wait of the state that it read. -/
def ExpireAct (state m busy : Term) (out : Term) : Prop :=
  Internal out →
    fact (outMachine out) "ceiling_ms" = fact m "ceiling_ms" ∧
    (mkey (outMachine out) "phase" = b "timeout" ∨ mkey (outMachine out) "phase" = b "activation") ∧
    ((outEffects out = [a "continue"] ∧ (state.get (a "wait") != mkey m "expected") = true) ∨
     (∃ now next, VerifiedKernel.AgentLoop.WaitExtension.decide (state.get (a "wait")) busy now
        (fact m "ceiling_ms") = .tuple [a "extend", next] ∧
        outEffects out = extendEffects (waitSetFor state next) next))

theorem expire_act {state m busy : Term} : Sat (ExpireAct state m busy) (expireN state m busy) := by
  unfold expireN
  unfold_native "VerifiedKernel.Session.Loop.expire"
  sat_walk
  all_goals first
    | (intro _
       have hw := RoundFrames.field_value ‹field state "wait" _ = _›
       subst hw
       loop_unfold
       refine ⟨?_, entry_phase _ _, Or.inl ⟨rfl, ‹_›⟩⟩
       simp only [outMachine_tuple]
       rw [fact_put_ne _ _ (by decide)])
    | (intro _
       have hw := RoundFrames.field_value ‹field state "wait" _ = _›
       subst hw
       have he := waitSetEvent_eq ‹waitSetEventN _ _ _ = _›
       subst he
       loop_unfold
       refine ⟨?_, entry_phase _ _, Or.inr ⟨_, _, ‹_›, ?_⟩⟩
       · simp only [outMachine_tuple]
         rw [fact_put_ne _ _ (by decide)]
       · simp [extendEffects, nil, atom_beq_self])
    | (unfold ExpireAct; loop_unfold; simp [Internal])

theorem timeoutEntry_act {ask : Loop.Ask} {state m : Term} : Sat (EntryAct state m) (timeoutEntryN ask state m) := by
  unfold timeoutEntryN
  unfold_native "VerifiedKernel.Session.Loop.timeoutEntry"
  sat_walk
  · unfold EntryAct; loop_unfold; simp [Internal]
  · refine Sat.mono expireEntry_act (fun out entry internal => ?_)
    obtain ⟨ceiling, busy, expected, plain⟩ := entry internal
    exact ⟨ceiling.trans (fact_put_ne _ _ (by decide) _), busy, expected, plain⟩

/-! ## One step of an activation chain -/

/-- The activation phases. -/
def ActPhase (m : Term) : Prop :=
  mkey m "phase" = b "activation" ∨ mkey m "phase" = b "router" ∨ mkey m "phase" = b "busy" ∨
    mkey m "phase" = b "timeout"

theorem text_eq {x y : String} (h : b x = b y) : x = y := by
  simp only [b, Term.text, Term.binary.injEq] at h
  exact String.toByteArray_inj.mp h

theorem not_busy_of {m : Term} {p : String} (h : mkey m "phase" = b p) (ne : p ≠ "busy") :
    mkey m "phase" ≠ b "busy" := by
  rw [h]; intro e; exact ne (text_eq e)

/-- One internal step of an activation chain. The output machine stays in the
activation phases and keeps the ceiling fact. A `busy` machine records the
wait that the step read. The step drops the phase rank without a write or a
commit, or it is a yield, an extension, or a changed wait. -/
def ActStep (state m ev out : Term) : Prop :=
  Internal out →
    ActPhase (outMachine out) ∧ fact (outMachine out) "ceiling_ms" = fact m "ceiling_ms" ∧
    (mkey (outMachine out) "phase" = b "busy" → mkey (outMachine out) "expected" = state.get (a "wait")) ∧
    (mkey (outMachine out) "phase" = b "router" → outEffects out = [.tuple [a "fact", a "canonical_router"]]) ∧
    ((inRank (outMachine out) < inRank m ∧ Plain (outEffects out)) ∨
     (∃ es, es ≠ [] ∧ YieldShape state es ∧ (state.get (a "wait")).isMap = true ∧
        mkey (outMachine out) "phase" ≠ b "busy" ∧
        outEffects out = [.tuple [a "write", list es], a "continue"]) ∨
     (∃ v now next, ev = .tuple [a "fact", v] ∧
        VerifiedKernel.AgentLoop.WaitExtension.decide (state.get (a "wait")) v now (fact m "ceiling_ms") =
          .tuple [a "extend", next] ∧
        outEffects out = extendEffects (waitSetFor state next) next ∧
        (mkey (outMachine out) "phase" = b "timeout" ∨ mkey (outMachine out) "phase" = b "activation")) ∨
     (mkey m "phase" = b "busy" ∧ outEffects out = [a "continue"] ∧
        mkey (outMachine out) "phase" ≠ b "busy" ∧
        (state.get (a "wait") != mkey m "expected") = true))

macro "act_absurd" : tactic => `(tactic| (
  have hp := phase_of_beq ‹(_ == b _) = true›
  rcases ‹ActPhase _› with h | h | h | h <;> exact absurd (text_eq (hp.symm.trans h)) (by decide)))

theorem act_continue {state m : Term} (phase : ActPhase m) :
    Sat (ActStep state m (a "continue")) (Loop.stepWith Loop.queryAsk state (.tuple [m, a "continue"])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  all_goals first
    | act_absurd
    | skip
  · -- activation
    have inPhase : mkey m "phase" = b "activation" := phase_of_beq ‹(_ == b "activation") = true›
    refine Sat.mono activation_act (fun out act internal => ?_)
    obtain ⟨ceiling, cases⟩ := act internal
    rcases cases with ⟨outPhase, answered, plain⟩ | ⟨outPhase, expected, plain⟩ |
        ⟨outPhase, answered, es, expected, j, j', yielded, nonempty, effects⟩
    · have absent := check_router_absent answered
      refine ⟨Or.inr (Or.inl outPhase), ceiling, fun busy => ?_, fun _ => plain, Or.inl ⟨?_, ?_⟩⟩
      · rw [outPhase] at busy; exact absurd (text_eq busy) (by decide)
      · rw [inRank_of outPhase, inRank_of inPhase]
        simp [phaseRank, binary_key_beq, absent]
      · rw [plain]; exact plain_fetch _
    · refine ⟨Or.inr (Or.inr (Or.inl outPhase)), ceiling, fun _ => expected, fun router => ?_,
        Or.inl ⟨?_, plain⟩⟩
      · rw [outPhase] at router; exact absurd (text_eq router) (by decide)
      · rw [inRank_of outPhase, inRank_of inPhase]
        simp (config := {decide := true}) only [phaseRank, if_false, if_true]
        split <;> omega
    · refine ⟨Or.inl outPhase, ceiling, fun busy => ?_, fun router => ?_,
        Or.inr (Or.inl ⟨es, nonempty, ?_, ?_, not_busy_of outPhase (by decide), effects⟩)⟩
      · rw [outPhase] at busy; exact absurd (text_eq busy) (by decide)
      · rw [outPhase] at router; exact absurd (text_eq router) (by decide)
      · rw [queryAsk_yield_events] at yielded
        rcases Sat.use waitYieldEvents_shape yielded with empty | ⟨events', same, shape⟩
        · cases empty; exact absurd rfl nonempty
        · cases same; exact shape
      · obtain ⟨k, k', run⟩ := answered
        rw [queryAsk_activation_next] at run
        exact Sat.use activationNext_yield_wait run rfl
  · -- timeout
    have inPhase : mkey m "phase" = b "timeout" := phase_of_beq ‹(_ == b "timeout") = true›
    refine Sat.mono timeoutEntry_act (fun out entry internal => ?_)
    obtain ⟨ceiling, busy, expected, plain⟩ := entry internal
    refine ⟨Or.inr (Or.inr (Or.inl busy)), ceiling, fun _ => expected, fun router => ?_, Or.inl ⟨?_, plain⟩⟩
    · rw [busy] at router; exact absurd (text_eq router) (by decide)
    · rw [inRank_of busy, inRank_of inPhase]
      simp [phaseRank, binary_key_beq]

theorem act_fact {state m v : Term} (phase : ActPhase m) (present : mkey m "phase" = b "router" → (v == nil) = false) :
    Sat (ActStep state m (.tuple [a "fact", v]))
      (Loop.stepWith Loop.queryAsk state (.tuple [m, .tuple [a "fact", v]])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  all_goals first
    | act_absurd
    | skip
  · -- router
    have inPhase : mkey m "phase" = b "router" := phase_of_beq ‹(_ == b "router") = true›
    refine Sat.mono activation_act (fun out act internal => ?_)
    obtain ⟨ceiling, cases⟩ := act internal
    rw [fact_put_ne _ _ (by decide)] at ceiling
    rcases cases with ⟨outPhase, answered, plain⟩ | ⟨outPhase, expected, plain⟩ |
        ⟨outPhase, answered, es, expected, j, j', yielded, nonempty, effects⟩
    · exfalso
      have absent := check_router_absent answered
      rw [mkey_put_same] at absent
      rw [present inPhase] at absent
      cases absent
    · refine ⟨Or.inr (Or.inr (Or.inl outPhase)), ceiling, fun _ => expected, fun router => ?_,
        Or.inl ⟨?_, plain⟩⟩
      · rw [outPhase] at router; exact absurd (text_eq router) (by decide)
      · rw [inRank_of outPhase, inRank_of inPhase]
        simp (config := {decide := true}) [phaseRank]
    · refine ⟨Or.inl outPhase, ceiling, fun busy => ?_, fun router => ?_,
        Or.inr (Or.inl ⟨es, nonempty, ?_, ?_, not_busy_of outPhase (by decide), effects⟩)⟩
      · rw [outPhase] at busy; exact absurd (text_eq busy) (by decide)
      · rw [outPhase] at router; exact absurd (text_eq router) (by decide)
      · rw [queryAsk_yield_events] at yielded
        rcases Sat.use waitYieldEvents_shape yielded with empty | ⟨events', same, shape⟩
        · cases empty; exact absurd rfl nonempty
        · cases same; exact shape
      · obtain ⟨k, k', run⟩ := answered
        rw [queryAsk_activation_next] at run
        exact Sat.use activationNext_yield_wait run rfl
  · -- busy
    have inPhase : mkey m "phase" = b "busy" := phase_of_beq ‹(_ == b "busy") = true›
    refine Sat.mono expire_act (fun out exp internal => ?_)
    obtain ⟨ceiling, outPhase, cases⟩ := exp internal
    have act : ActPhase (outMachine out) := by
      rcases outPhase with h | h
      · exact Or.inr (Or.inr (Or.inr h))
      · exact Or.inl h
    have notBusy : mkey (outMachine out) "phase" = b "busy" → mkey (outMachine out) "expected" = state.get (a "wait") := by
      intro busy
      rcases outPhase with h | h <;> (rw [h] at busy; exact absurd (text_eq busy) (by decide))
    have notRouter : mkey (outMachine out) "phase" = b "router" →
        outEffects out = [.tuple [a "fact", a "canonical_router"]] := by
      intro router
      rcases outPhase with h | h <;> (rw [h] at router; exact absurd (text_eq router) (by decide))
    rcases cases with ⟨only, changed⟩ | ⟨now, next, decided, effects⟩
    · have outNotBusy : mkey (outMachine out) "phase" ≠ b "busy" := by
        rcases outPhase with h | h
        · exact not_busy_of h (by decide)
        · exact not_busy_of h (by decide)
      exact ⟨act, ceiling, notBusy, notRouter, Or.inr (Or.inr (Or.inr ⟨inPhase, only, outNotBusy, changed⟩))⟩
    · exact ⟨act, ceiling, notBusy, notRouter, Or.inr (Or.inr (Or.inl ⟨v, now, next, rfl, decided, effects, outPhase⟩))⟩

/-! ## The entry step -/

/-- An entry event of an activation chain: `{:activate, facts}` or
`{:wait_timeout, wait_id, source, facts}`. -/
def ChainEntry (ev : Term) : Prop :=
  (∃ facts, ev = .tuple [a "activate", facts]) ∨ ∃ waitId source facts, ev = .tuple [a "wait_timeout", waitId, source, facts]

/-- The internal outputs of an entry step. -/
def EntryStep (state ev out : Term) : Prop :=
  Internal out →
    ActPhase (outMachine out) ∧ fact (outMachine out) "ceiling_ms" = mkey (entryRound nil ev) "ceiling_ms" ∧
    (mkey (outMachine out) "phase" = b "busy" → mkey (outMachine out) "expected" = state.get (a "wait")) ∧
    (mkey (outMachine out) "phase" = b "router" → outEffects out = [.tuple [a "fact", a "canonical_router"]]) ∧
    (Plain (outEffects out) ∨
     (∃ es, es ≠ [] ∧ YieldShape state es ∧ (state.get (a "wait")).isMap = true ∧
        mkey (outMachine out) "phase" ≠ b "busy" ∧
        outEffects out = [.tuple [a "write", list es], a "continue"]))

theorem fact_entry_map (facts : Term) (entries : List (Term × Term)) :
    fact (Term.map ((b "round", facts) :: entries)) "ceiling_ms" = mkey facts "ceiling_ms" := by
  have round : mkey (Term.map ((b "round", facts) :: entries)) "round" = facts := by
    simp [mkey, Term.isMap, Term.get, List.find?, term_beq_self]
  unfold fact
  rw [round]

theorem act_enter {state ev : Term} (entry : ChainEntry ev) :
    Sat (EntryStep state ev) (Loop.stepWith Loop.queryAsk state (.tuple [nil, ev])) := by
  rcases entry with ⟨facts, rfl⟩ | ⟨waitId, source, facts, rfl⟩
  · unfold Loop.stepWith
    dsimp only
    apply Sat.bind
    intro sid _ _ _
    simp only [a]
    refine Sat.mono activation_act (fun out act internal => ?_)
    obtain ⟨ceiling, cases⟩ := act internal
    rw [fact_entry_map facts] at ceiling
    rcases cases with ⟨outPhase, answered, plain⟩ | ⟨outPhase, expected, plain⟩ |
        ⟨outPhase, answered, es, expected, j, j', yielded, nonempty, effects⟩
    · refine ⟨Or.inr (Or.inl outPhase), ceiling, fun busy => ?_, fun _ => plain, Or.inl ?_⟩
      · rw [outPhase] at busy; exact absurd (text_eq busy) (by decide)
      · rw [plain]; exact plain_fetch _
    · refine ⟨Or.inr (Or.inr (Or.inl outPhase)), ceiling, fun _ => expected, fun router => ?_, Or.inl plain⟩
      rw [outPhase] at router; exact absurd (text_eq router) (by decide)
    · refine ⟨Or.inl outPhase, ceiling, fun busy => ?_, fun router => ?_,
        Or.inr ⟨es, nonempty, ?_, ?_, not_busy_of outPhase (by decide), effects⟩⟩
      · rw [outPhase] at busy; exact absurd (text_eq busy) (by decide)
      · rw [outPhase] at router; exact absurd (text_eq router) (by decide)
      · rw [queryAsk_yield_events] at yielded
        rcases Sat.use waitYieldEvents_shape yielded with empty | ⟨events', same, shape⟩
        · cases empty; exact absurd rfl nonempty
        · cases same; exact shape
      · obtain ⟨k, k', run⟩ := answered
        rw [queryAsk_activation_next] at run
        exact Sat.use activationNext_yield_wait run rfl
  · unfold Loop.stepWith
    dsimp only
    apply Sat.bind
    intro sid _ _ _
    simp only [a]
    refine Sat.mono timeoutEntry_act (fun out entry internal => ?_)
    obtain ⟨ceiling, busy, expected, plain⟩ := entry internal
    rw [fact_entry_map facts] at ceiling
    refine ⟨Or.inr (Or.inr (Or.inl busy)), ceiling, fun _ => expected, fun router => ?_, Or.inl plain⟩
    rw [busy] at router; exact absurd (text_eq router) (by decide)

/-! ## Batches on the host model -/

theorem batch_session {s t : Term} {events : List Term} (batch : ResidentBatch s events t) :
    t.get (a "session_id") = s.get (a "session_id") := by
  induction batch with
  | nil => rfl
  | cons head tail ih => exact ih.trans (resident_prepared head).session

theorem inner_wait_set {s e t : Term} {j r : List Term} (kind : e.get (b "type") = b "wait_set")
    (h : inner s e j = .ok (t, r)) : t.get (a "wait") = e.get (b "wait") := by
  have h' : (Data.event e "wait" >>= fun v => write s [("wait", v)]) j = .ok (t, r) := by
    simpa +decide [inner, kind] using h
  obtain ⟨v, _, read, written⟩ := bind_ok h'
  rw [(access_ok read).1] at written
  obtain ⟨_, written⟩ := write_cons written
  rw [pure_ok written]
  exact get_put_same _ _ _

theorem landed_extension (d next : Term) : landed [waitSetFor d next] (list []) = [waitSetFor d next] := by
  simp [landed, hwmOf, PendingRevision.hwmEvents, nil, list, Term.isInteger]

/-- The commit of an extension leaves the extended wait. -/
theorem extension_lands {d next t : Term} (land : ResidentBatch d (landed [waitSetFor d next] (list [])) t) :
    t.get (a "wait") = next := by
  rw [landed_extension] at land
  cases land with
  | cons head rest =>
    cases rest with
    | nil =>
      obtain ⟨n, normalized, j, r, prepared, frame⟩ := resident_prepared head
      rw [frame "wait" (by decide) (by decide)]
      have keys : BinaryKeys (waitSetFor d next) := by simp [BinaryKeys, waitSetFor, b, Term.text, Term.isBinary]
      cases normalized with
      | none =>
        exact (prepareTrusted_canonical_not_skipped keys (by simp +decide [waitSetFor, Term.get]) prepared).elim
      | some event =>
        obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
        have same := shallowStringify_binary_keys keys read
        subst same
        rw [inner_wait_set (by simp +decide [waitSetFor, Term.get]) reduced]
        simp +decide [waitSetFor, Term.get]

/-! ## The host potential of an activation chain -/

/-- The host answers the Router fact with a present value (`true` or
`false`, never `nil`). `canonical_router_session?` returns a boolean. -/
def RouterFactsPresent (cfg : HostConfig) : Prop :=
  ∀ v, cfg.fact (a "canonical_router") v → (v == nil) = false

/-- The control of a state inside an activation chain after its first step. -/
def ChainControl : Control → Prop
  | .feed m ev => ActPhase m ∧ (ev = a "continue" ∨ ∃ v, ev = .tuple [a "fact", v])
  | .perform m effs => ActPhase m ∧ Internal (.tuple [m, list effs])
  | _ => False

/-- The invariant of an activation chain. The durable and working states
belong to one session. The next step reads an activation machine with a
ceiling of at most `C`, or it is the entry step. A pending `write` is a
provider-wait yield of this session. -/
def InChain (C : Int) (σ : HostState) : Prop :=
  σ.durable.get (a "session_id") = σ.working.get (a "session_id") ∧
  match σ.control with
  | .feed m ev =>
    (ActPhase m ∧ integerValue (fact m "ceiling_ms") ≤ C ∧
      (ev = a "continue" ∨ ∃ v, ev = .tuple [a "fact", v] ∧ (mkey m "phase" = b "router" → (v == nil) = false))) ∨
    (m = nil ∧ ChainEntry ev ∧ integerValue (mkey (entryRound nil ev) "ceiling_ms") ≤ C)
  | .perform m effs =>
    ActPhase m ∧ integerValue (fact m "ceiling_ms") ≤ C ∧ Internal (.tuple [m, list effs]) ∧
    (mkey m "phase" = b "router" → effs = [.tuple [a "fact", a "canonical_router"]]) ∧
    (∀ es, .tuple [a "write", list es] ∈ effs → effs = [.tuple [a "write", list es], a "continue"] ∧
      mkey m "phase" ≠ b "busy" ∧ ∃ s₀, YieldShape s₀ es ∧ s₀.get (a "session_id") = σ.working.get (a "session_id"))
  | _ => False

open Classical in
/-- The rank of the next step: the phase rank, or 4 for the entry step. -/
noncomputable def ctlRank : Control → Nat
  | .feed m _ => if mkey m "phase" = nil then 4 else inRank m
  | .perform m _ => inRank m
  | _ => 0

/-- The step effects that the host still performs contain a `write`. -/
def WritePending : Control → Prop
  | .perform _ effs => ∃ es, Term.tuple [a "write", list es] ∈ effs
  | _ => False

open Classical in
/-- One yield is possible: the working state has a wait, and no yield write is pending. -/
noncomputable def yieldRoom (σ : HostState) : Nat :=
  if WritePending σ.control then 0 else if (σ.working.get (a "wait")).isMap = true then 1 else 0

/-- The extensions that a wait still allows under the ceiling `C`. -/
def extRoom (C : Int) (w : Term) : Nat :=
  if w.isMap = true then ((C - waitNatural w "extended_ms") / 1000).toNat else 0

/-- The machine of a feed or perform control. -/
def ctlMachine : Control → Term
  | .feed m _ => m
  | .perform m _ => m
  | _ => nil

open Classical in
/-- A changed wait is possible: a `busy` machine recorded another wait than the working one. -/
noncomputable def changedRoom (σ : HostState) : Nat :=
  if mkey (ctlMachine σ.control) "phase" = b "busy" ∧
      (σ.working.get (a "wait") != mkey (ctlMachine σ.control) "expected") = true then 1 else 0

open Classical in
/-- Another writer changed the durable state after the host last read it. -/
noncomputable def envRoom (σ : HostState) : Nat := if σ.pending = false ∧ σ.durable ≠ σ.working then 1 else 0

def extMax (C : Int) : Nat := (C / 1000).toNat

/-- The weight of one environment write. -/
def envWeight (C : Int) : Nat := 4 * extMax C + 13

noncomputable def restPot (C : Int) (σ : HostState) : Nat :=
  ctlRank σ.control + 4 * (yieldRoom σ + extRoom C (σ.working.get (a "wait")) + changedRoom σ)

/-- The potential of an activation chain. -/
noncomputable def chainPot (C : Int) (σ : HostState) : Nat := restPot C σ + envWeight C * envRoom σ

theorem ctlRank_le (c : Control) : ctlRank c ≤ 4 := by
  have := inRank_le (ctlMachine c)
  cases c with
  | feed m ev => simp only [ctlRank, ctlMachine] at this ⊢; split <;> omega
  | perform m effs => simp only [ctlRank, ctlMachine] at this ⊢; omega
  | idle => simp [ctlRank]
  | running m calls => simp [ctlRank]

theorem yieldRoom_le (σ : HostState) : yieldRoom σ ≤ 1 := by
  unfold yieldRoom; split
  · omega
  · split <;> omega

theorem changedRoom_le (σ : HostState) : changedRoom σ ≤ 1 := by
  unfold changedRoom; split <;> omega

theorem extRoom_le (C : Int) (w : Term) : extRoom C w ≤ extMax C := by
  unfold extRoom extMax
  split
  · have := waitNatural_nonneg w "extended_ms"
    have : (C - waitNatural w "extended_ms") / 1000 ≤ C / 1000 := Int.ediv_le_ediv (by decide) (by omega)
    omega
  · omega

theorem restPot_lt (C : Int) (σ : HostState) : restPot C σ < envWeight C := by
  unfold restPot envWeight
  have := ctlRank_le σ.control
  have := yieldRoom_le σ
  have := changedRoom_le σ
  have := extRoom_le C (σ.working.get (a "wait"))
  omega

theorem envRoom_le (σ : HostState) : envRoom σ ≤ 1 := by
  unfold envRoom; split <;> omega

/-- The bound of the potential. -/
def chainBound (C : Int) : Nat := 2 * envWeight C

theorem chainPot_le (C : Int) (σ : HostState) : chainPot C σ ≤ chainBound C := by
  unfold chainPot chainBound
  have := restPot_lt C σ
  have := envRoom_le σ
  have : envWeight C * envRoom σ ≤ envWeight C * 1 := Nat.mul_le_mul_left _ this
  omega

/-- After another writer changed the durable state, reading it pays for any change of the rest. -/
theorem pot_jump {C : Int} {σ σ' : HostState} (room : envRoom σ = 1) (clear : envRoom σ' = 0) :
    1 + chainPot C σ' ≤ chainPot C σ := by
  unfold chainPot
  rw [room, clear]
  have := restPot_lt C σ'
  omega

/-! ## One kernel step on the host -/

theorem actPhase_ne_nil {m : Term} (act : ActPhase m) : ¬ mkey m "phase" = nil := by
  intro h
  rcases act with e | e | e | e <;> (rw [e] at h; simp [nil, b, Term.text] at h)

theorem ctlRank_feed {m ev : Term} (act : ActPhase m) : ctlRank (.feed m ev) = inRank m := by
  simp [ctlRank, actPhase_ne_nil act]

theorem ctlRank_perform (m : Term) (effs : List Term) : ctlRank (.perform m effs) = inRank m := by
  simp [ctlRank]

theorem ctlRank_entry (ev : Term) : ctlRank (.feed nil ev) = 4 := by
  simp [ctlRank, mkey, nil, Term.isMap]

/-- One kernel step inside an activation chain, read on the state `s`. -/
def KStep (C : Int) (s m ev out : Term) : Prop :=
  Internal out →
    ActPhase (outMachine out) ∧ integerValue (fact (outMachine out) "ceiling_ms") ≤ C ∧
    (mkey (outMachine out) "phase" = b "busy" → mkey (outMachine out) "expected" = s.get (a "wait")) ∧
    (mkey (outMachine out) "phase" = b "router" → outEffects out = [.tuple [a "fact", a "canonical_router"]]) ∧
    ((inRank (outMachine out) < ctlRank (.feed m ev) ∧ Plain (outEffects out)) ∨
     (∃ es, es ≠ [] ∧ YieldShape s es ∧ (s.get (a "wait")).isMap = true ∧ mkey (outMachine out) "phase" ≠ b "busy" ∧
        outEffects out = [.tuple [a "write", list es], a "continue"]) ∨
     (∃ v now next, VerifiedKernel.AgentLoop.WaitExtension.decide (s.get (a "wait")) v now (fact m "ceiling_ms") =
          .tuple [a "extend", next] ∧ integerValue (fact m "ceiling_ms") ≤ C ∧
        outEffects out = extendEffects (waitSetFor s next) next ∧ mkey (outMachine out) "phase" ≠ b "busy") ∨
     (mkey m "phase" = b "busy" ∧ outEffects out = [a "continue"] ∧ mkey (outMachine out) "phase" ≠ b "busy" ∧
        (s.get (a "wait") != mkey m "expected") = true))

theorem kstep {C : Int} {σ : HostState} {s m ev : Term} (inv : InChain C σ) (feed : σ.control = .feed m ev) :
    Sat (KStep C s m ev) (Loop.stepWith Loop.queryAsk s (.tuple [m, ev])) := by
  obtain ⟨_, ctl⟩ := inv
  rw [feed] at ctl
  rcases ctl with ⟨act, ceiling, answer⟩ | ⟨rfl, entry, ceiling⟩
  · have rank := ctlRank_feed (ev := ev) act
    have lift : ∀ out, ActStep s m ev out → KStep C s m ev out := by
      intro out step internal
      obtain ⟨act', ceiling', busy, router, cases⟩ := step internal
      refine ⟨act', by rw [ceiling']; exact ceiling, busy, router, ?_⟩
      rw [rank]
      rcases cases with drop | ⟨es, nonempty, shape, isMap, notBusy, effects⟩ |
          ⟨v, now, next, _, decided, effects, outPhase⟩ | ⟨inBusy, only, notBusy, changed⟩
      · exact Or.inl drop
      · exact Or.inr (Or.inl ⟨es, nonempty, shape, isMap, notBusy, effects⟩)
      · refine Or.inr (Or.inr (Or.inl ⟨v, now, next, decided, ceiling, effects, ?_⟩))
        rcases outPhase with h | h
        · exact not_busy_of h (by decide)
        · exact not_busy_of h (by decide)
      · exact Or.inr (Or.inr (Or.inr ⟨inBusy, only, notBusy, changed⟩))
    rcases answer with rfl | ⟨v, rfl, present⟩
    · exact Sat.mono (act_continue act) lift
    · exact Sat.mono (act_fact act present) lift
  · refine Sat.mono (act_enter entry) (fun out step internal => ?_)
    obtain ⟨act', ceiling', busy, router, cases⟩ := step internal
    refine ⟨act', by rw [ceiling']; exact ceiling, busy, router, ?_⟩
    rw [ctlRank_entry]
    rcases cases with plain | ⟨es, nonempty, shape, isMap, notBusy, effects⟩
    · exact Or.inl ⟨by have := inRank_le (outMachine out); omega, plain⟩
    · exact Or.inr (Or.inl ⟨es, nonempty, shape, isMap, notBusy, effects⟩)

/-! ## Potential facts -/

theorem yieldRoom_feed {σ : HostState} {m ev : Term} (feed : σ.control = .feed m ev) :
    yieldRoom σ = if (σ.working.get (a "wait")).isMap = true then 1 else 0 := by
  unfold yieldRoom
  rw [feed]
  simp [WritePending]

theorem yieldRoom_write {σ : HostState} {m : Term} {effs : List Term} (ctl : σ.control = .perform m effs)
    {es : List Term} (mem : Term.tuple [a "write", list es] ∈ effs) : yieldRoom σ = 0 := by
  unfold yieldRoom
  rw [ctl]
  simp only [WritePending]
  exact if_pos ⟨es, mem⟩

theorem yieldRoom_nowrite {σ : HostState} {m : Term} {effs : List Term} (ctl : σ.control = .perform m effs)
    (none : ∀ es, Term.tuple [a "write", list es] ∉ effs) :
    yieldRoom σ = if (σ.working.get (a "wait")).isMap = true then 1 else 0 := by
  unfold yieldRoom
  rw [ctl]
  simp only [WritePending]
  exact if_neg (fun ⟨es, mem⟩ => none es mem)

theorem write_kind {es : List Term} : effectKind (.tuple [a "write", list es]) = .write := rfl

theorem plain_nowrite {effs : List Term} (plain : Plain effs) : ∀ es, Term.tuple [a "write", list es] ∉ effs :=
  fun es mem => (plain _ mem).1 write_kind

theorem changedRoom_of_expected {σ : HostState} {m : Term}
    (machine : ctlMachine σ.control = m) (expected : mkey m "phase" = b "busy" → mkey m "expected" = σ.working.get (a "wait")) :
    changedRoom σ = 0 := by
  unfold changedRoom
  rw [machine]
  rw [if_neg]
  rintro ⟨busy, ne⟩
  rw [expected busy] at ne
  simp [bne, term_beq_self] at ne

theorem changedRoom_not_busy {σ : HostState} {m : Term}
    (machine : ctlMachine σ.control = m) (notBusy : mkey m "phase" ≠ b "busy") : changedRoom σ = 0 := by
  unfold changedRoom
  rw [machine, if_neg (fun h => notBusy h.1)]

theorem changedRoom_one {σ : HostState} {m : Term} (machine : ctlMachine σ.control = m)
    (busy : mkey m "phase" = b "busy") (ne : (σ.working.get (a "wait") != mkey m "expected") = true) :
    changedRoom σ = 1 := by
  unfold changedRoom
  rw [machine, if_pos ⟨busy, ne⟩]

theorem envRoom_zero_of {σ : HostState} (h : σ.pending = true ∨ σ.durable = σ.working) : envRoom σ = 0 := by
  unfold envRoom
  rw [if_neg]
  rintro ⟨pend, ne⟩
  rcases h with h | h
  · rw [h] at pend; cases pend
  · exact ne h

theorem envRoom_one {σ : HostState} (clean : σ.pending = false) (ne : σ.durable ≠ σ.working) : envRoom σ = 1 := by
  unfold envRoom
  rw [if_pos ⟨clean, ne⟩]

theorem internal_post {m : Term} {pre post : List Term} {x : Term}
    (h : Internal (.tuple [m, list post])) : Internal (.tuple [m, list (pre ++ x :: post)]) := by
  unfold Internal at h ⊢
  simp only [outEffects_tuple] at h ⊢
  cases post with
  | nil => simp at h
  | cons y ys =>
    have last : (pre ++ x :: y :: ys).getLast? = (y :: ys).getLast? := by
      simp [List.getLast?_append, List.getLast?_cons]
    rw [last]
    exact h

/-! ## Kernel steps on the host -/

theorem extend_commit_mem (event next : Term) :
    commitEffect [event] (list []) nil ∈ extendEffects event next := by
  simp [extendEffects, commitEffect]

theorem write_mem_pair {es es' : List Term} (mem : Term.tuple [a "write", list es] ∈
    [Term.tuple [a "write", list es'], a "continue"]) : es = es' := by
  simp only [List.mem_cons, List.not_mem_nil, or_false] at mem
  rcases mem with h | h
  · simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq, and_true, true_and] at h
    exact h
  · simp [a] at h

theorem write_not_continue {es : List Term} : Term.tuple [a "write", list es] ∉ [a "continue"] := by
  simp [a]

/-- A kernel step without a commit: `local` on the working state, or
`reroute` on the durable state. -/
theorem plain_step {C : Int} {σ σ' : HostState} {m ev m' : Term} {effs : List Term}
    (inv : InChain C σ) (feed : σ.control = .feed m ev)
    (step : StepOK Loop.queryAsk σ'.working m ev m' effs) (noCommit : NoCommit effs)
    (ctl : σ'.control = .perform m' effs) (chain : ChainControl σ'.control)
    (dur : σ'.durable = σ.durable) (pend : σ'.pending = σ.pending)
    (read : σ'.working = σ.working ∨ (σ.pending = false ∧ σ'.working = σ.durable)) :
    1 + chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  rw [ctl] at chain
  obtain ⟨_, internal⟩ := chain
  obtain ⟨j, j', run⟩ := step
  have k := Sat.use (kstep (s := σ'.working) inv feed) run internal
  simp only [outMachine_tuple, outEffects_tuple] at k
  obtain ⟨act', ceiling, busy, router, cases⟩ := k
  have sid : σ'.durable.get (a "session_id") = σ'.working.get (a "session_id") := by
    rcases read with same | ⟨_, same⟩
    · rw [dur, same]; exact inv.1
    · rw [dur, same]
  have inv' : InChain C σ' := by
    refine ⟨sid, ?_⟩
    rw [ctl]
    refine ⟨act', ceiling, internal, router, fun es mem => ?_⟩
    rcases cases with ⟨_, plain⟩ | ⟨es', _, shape, _, notBusy, effects⟩ | ⟨_, _, _, _, _, effects, _⟩ |
        ⟨_, only, _, _⟩
    · exact absurd mem (plain_nowrite plain es)
    · rw [effects] at mem ⊢
      have same := write_mem_pair mem
      subst same
      exact ⟨rfl, notBusy, σ'.working, shape, rfl⟩
    · exact absurd (effects ▸ extend_commit_mem _ _) (noCommit _ _ _)
    · rw [only] at mem; exact absurd mem write_not_continue
  refine ⟨?_, inv'⟩
  by_cases same : σ'.working = σ.working
  · have env : envRoom σ' = envRoom σ := by
      unfold envRoom; rw [dur, pend, same]
    have changed' : changedRoom σ' = 0 := by
      refine changedRoom_of_expected (m := m') (by rw [ctl]; rfl) busy
    have yield := yieldRoom_feed feed
    have rank : ctlRank σ'.control = inRank m' := by rw [ctl]; exact ctlRank_perform _ _
    have rankLe := inRank_le m'
    unfold chainPot restPot
    rw [env, changed', rank, same]
    rcases cases with ⟨drop, plain⟩ | ⟨es, _, shape, isMap, notBusy, effects⟩ | ⟨_, _, _, _, _, effects, _⟩ |
        ⟨inBusy, only, _, changed⟩
    · have yield' := yieldRoom_nowrite ctl (plain_nowrite plain)
      rw [same] at yield'
      rw [yield', ← yield]
      rw [feed]
      omega
    · have yield' := yieldRoom_write ctl (es := es) (by rw [effects]; simp)
      rw [same] at isMap
      rw [yield', yield, if_pos isMap]
      have := ctlRank_le σ.control
      omega
    · exact absurd (effects ▸ extend_commit_mem _ _) (noCommit _ _ _)
    · have yield' := yieldRoom_nowrite ctl (by rw [only]; exact fun es => write_not_continue)
      rw [same] at yield' changed
      have changedOne : changedRoom σ = 1 := changedRoom_one (m := m) (by rw [feed]; rfl) inBusy changed
      rw [yield', ← yield, changedOne]
      omega
  · rcases read with same' | ⟨clean, readDur⟩
    · exact absurd same' same
    have room : envRoom σ = 1 := envRoom_one clean (fun e => same (readDur.trans e))
    have clear : envRoom σ' = 0 := envRoom_zero_of (Or.inr (dur.trans readDur.symm))
    exact pot_jump room clear

theorem pre_commit_extend {pre post events : List Term} {opts mode event next : Term}
    (h : pre ++ commitEffect events opts mode :: post = extendEffects event next) :
    pre = [] ∧ events = [event] ∧ opts = list [] ∧
      post = [.tuple [a "notify", a "wait_extended", .tuple [next, b "recovery"]], a "continue"] := by
  unfold extendEffects commitEffect at h
  rcases pre with _ | ⟨x, _ | ⟨y, _ | ⟨z, rest⟩⟩⟩
  · simp only [List.nil_append, List.cons.injEq, Term.tuple.injEq, list, Term.list.injEq, and_true,
      true_and] at h
    obtain ⟨⟨e, o, _⟩, p⟩ := h
    exact ⟨rfl, e, o, p⟩
  · simp [a] at h
  · simp [a] at h
  · simp at h

theorem extRoom_step {C : Int} {w next : Term} (isMap : w.isMap = true) (isMap' : next.isMap = true)
    (grows : waitNatural w "extended_ms" + 1000 ≤ waitNatural next "extended_ms")
    (inside : waitNatural next "extended_ms" ≤ C) : extRoom C next + 1 ≤ extRoom C w := by
  unfold extRoom
  rw [if_pos isMap, if_pos isMap']
  have := waitNatural_nonneg w "extended_ms"
  omega

/-- A kernel step with a commit: `commit` on the durable state or
`fenceCommit` on the working state. In an activation chain it is a wait
extension. -/
theorem commit_step {C : Int} {σ σ' : HostState} {m ev m' s t opts mode : Term}
    {pre events post : List Term}
    (inv : InChain C σ) (feed : σ.control = .feed m ev)
    (step : StepOK Loop.queryAsk s m ev m' (pre ++ commitEffect events opts mode :: post))
    (land : ResidentBatch s (landed events opts) t)
    (ctl : σ'.control = .perform m' post) (chain : ChainControl σ'.control)
    (work : σ'.working = t) (dur : σ'.durable = t)
    (read : s = σ.working ∨ (σ.pending = false ∧ s = σ.durable)) :
    1 + chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  rw [ctl] at chain
  obtain ⟨_, internal⟩ := chain
  obtain ⟨j, j', run⟩ := step
  have k := Sat.use (kstep (s := s) inv feed) run (internal_post internal)
  simp only [outMachine_tuple, outEffects_tuple] at k
  obtain ⟨act', ceiling, _, router, cases⟩ := k
  have commitMem : commitEffect events opts mode ∈ pre ++ commitEffect events opts mode :: post := by simp
  rcases cases with ⟨_, plain⟩ | ⟨es, _, _, _, _, effects⟩ | ⟨v, now, next, decided, ceilingM, effects, notBusy⟩ |
      ⟨_, only, _, _⟩
  · exact absurd rfl (plain _ commitMem).2
  · rw [effects] at commitMem; simp [commitEffect, a] at commitMem
  · obtain ⟨rfl, rfl, rfl, rfl⟩ := pre_commit_extend effects
    have waitT : t.get (a "wait") = next := extension_lands land
    obtain ⟨_, _, isMap', _, inside, grows, _⟩ := wait_extension_budget decided
    obtain ⟨isMap, _⟩ := decide_extend decided
    have sid : σ'.durable.get (a "session_id") = σ'.working.get (a "session_id") := by rw [dur, work]
    have postNoWrite : ∀ es, Term.tuple [a "write", list es] ∉
        [Term.tuple [a "notify", a "wait_extended", .tuple [next, b "recovery"]], a "continue"] := by
      intro es mem; simp [a] at mem
    have inv' : InChain C σ' := by
      refine ⟨sid, ?_⟩
      rw [ctl]
      refine ⟨act', ceiling, internal, fun r => ?_, fun es mem => absurd mem (postNoWrite es)⟩
      have := router r
      simp [a] at this
    refine ⟨?_, inv'⟩
    by_cases same : s = σ.working
    · subst same
      have env : envRoom σ' = 0 := envRoom_zero_of (Or.inr (dur.trans work.symm))
      have changed' : changedRoom σ' = 0 := changedRoom_not_busy (m := m') (by rw [ctl]; rfl) notBusy
      have yield := yieldRoom_feed feed
      have yield' := yieldRoom_nowrite ctl postNoWrite
      rw [work, waitT, if_pos isMap'] at yield'
      rw [if_pos isMap] at yield
      have room := extRoom_step (C := C) isMap isMap' grows (Int.le_trans inside ceilingM)
      have rank : ctlRank σ'.control = inRank m' := by rw [ctl]; exact ctlRank_perform _ _
      have rankLe := inRank_le m'
      unfold chainPot restPot
      rw [env, changed', rank, yield', yield, work, waitT]
      omega
    · rcases read with same' | ⟨clean, readDur⟩
      · exact absurd same' same
      have room : envRoom σ = 1 := envRoom_one clean (fun e => same (readDur.trans e))
      have clear : envRoom σ' = 0 := envRoom_zero_of (Or.inr (dur.trans work.symm))
      exact pot_jump room clear
  · rw [only] at commitMem; simp [commitEffect, a] at commitMem

/-! ## Host transitions without a kernel step -/

theorem skip_step {C : Int} {σ σ' : HostState} {m e : Term} {rest : List Term}
    (inv : InChain C σ) (perform : σ.control = .perform m (e :: rest))
    (kind : effectKind e = .notify ∨ effectKind e = .setTimer ∨ effectKind e = .cancelTimer)
    (ctl : σ'.control = .perform m rest) (chain : ChainControl σ'.control)
    (same : σ'.working = σ.working ∧ σ'.durable = σ.durable ∧ σ'.pending = σ.pending) :
    chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  obtain ⟨work, dur, pend⟩ := same
  obtain ⟨sid, ctlInv⟩ := inv
  rw [perform] at ctlInv
  obtain ⟨act, ceiling, _, router, writes⟩ := ctlInv
  have notWrite : ∀ es, e ≠ .tuple [a "write", list es] := by
    intro es h; subst h; simp [effectKind] at kind
  have inv' : InChain C σ' := by
    refine ⟨by rw [work, dur]; exact sid, ?_⟩
    rw [ctl] at chain ⊢
    refine ⟨act, ceiling, chain.2, fun r => ?_, fun es mem => ?_⟩
    · have := router r
      simp only [List.cons.injEq] at this
      rw [this.1] at kind
      simp [effectKind] at kind
    · obtain ⟨pair, _⟩ := writes es (List.mem_cons_of_mem _ mem)
      simp only [List.cons.injEq] at pair
      exact absurd pair.1 (notWrite es)
  refine ⟨?_, inv'⟩
  have yieldSame : yieldRoom σ' = yieldRoom σ := by
    unfold yieldRoom
    rw [perform, ctl, work]
    simp only [WritePending]
    congr 1
    apply propext
    constructor
    · rintro ⟨es, mem⟩; exact ⟨es, List.mem_cons_of_mem _ mem⟩
    · rintro ⟨es, mem⟩
      rcases List.mem_cons.mp mem with h | h
      · exact absurd h.symm (notWrite es)
      · exact ⟨es, h⟩
  have changedSame : changedRoom σ' = changedRoom σ := by
    unfold changedRoom; rw [perform, ctl, work]; rfl
  have envSame : envRoom σ' = envRoom σ := by
    unfold envRoom; rw [work, dur, pend]
  unfold chainPot restPot
  rw [yieldSame, changedSame, envSame, work, ctl, perform, ctlRank_perform, ctlRank_perform]
  exact Nat.le_refl _

theorem write_step {C : Int} {σ σ' : HostState} {m t : Term} {es rest : List Term}
    (inv : InChain C σ) (perform : σ.control = .perform m (.tuple [a "write", list es] :: rest))
    (land : ResidentBatch σ.working es t)
    (ctl : σ'.control = .perform m rest) (chain : ChainControl σ'.control)
    (work : σ'.working = t) (dur : σ'.durable = σ.durable) (pend : σ'.pending = true) :
    chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  obtain ⟨sid, ctlInv⟩ := inv
  rw [perform] at ctlInv
  obtain ⟨act, ceiling, _, router, writes⟩ := ctlInv
  obtain ⟨pair, notBusy, s₀, shape, s₀sid⟩ := writes es List.mem_cons_self
  simp only [List.cons.injEq, true_and] at pair
  subst pair
  have cleared : t.get (a "wait") = nil := yield_clears_wait_of shape s₀sid.symm land
  have inv' : InChain C σ' := by
    refine ⟨by rw [dur, work, batch_session land]; exact sid, ?_⟩
    rw [ctl] at chain ⊢
    refine ⟨act, ceiling, chain.2, fun r => ?_, fun es' mem => absurd mem write_not_continue⟩
    have := router r
    simp [a] at this
  refine ⟨?_, inv'⟩
  have yield' : yieldRoom σ' = 0 := by
    rw [yieldRoom_nowrite ctl (fun _ => write_not_continue), work, cleared]
    simp [nil, Term.isMap]
  have ext' : extRoom C (σ'.working.get (a "wait")) = 0 := by
    rw [work, cleared]; simp [extRoom, nil, Term.isMap]
  have changed' : changedRoom σ' = 0 := changedRoom_not_busy (m := m) (by rw [ctl]; rfl) notBusy
  have env' : envRoom σ' = 0 := envRoom_zero_of (Or.inl pend)
  unfold chainPot restPot
  rw [yield', ext', changed', env', ctl, perform, ctlRank_perform, ctlRank_perform]
  omega

theorem reply_step {C : Int} {cfg : HostConfig} (present : RouterFactsPresent cfg) {σ σ' : HostState}
    {m effect event : Term}
    (inv : InChain C σ) (perform : σ.control = .perform m [effect]) (answer : HostReply cfg σ.working effect event)
    (ctl : σ'.control = .feed m event) (chain : ChainControl σ'.control)
    (same : σ'.working = σ.working ∧ σ'.durable = σ.durable ∧ σ'.pending = σ.pending) :
    chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  obtain ⟨work, dur, pend⟩ := same
  obtain ⟨sid, ctlInv⟩ := inv
  rw [perform] at ctlInv
  obtain ⟨act, ceiling, internal, router, _⟩ := ctlInv
  have inv' : InChain C σ' := by
    refine ⟨by rw [work, dur]; exact sid, ?_⟩
    rw [ctl] at chain ⊢
    refine Or.inl ⟨act, ceiling, ?_⟩
    cases answer with
    | «continue» => exact Or.inl rfl
    | store => simp [ChainControl, a] at chain
    | @fact name value answered =>
      refine Or.inr ⟨value, rfl, fun r => ?_⟩
      have := router r
      simp only [List.cons.injEq, Term.tuple.injEq, and_true, true_and] at this
      subst this
      exact present value answered
  refine ⟨?_, inv'⟩
  have noWrite : ∀ es, Term.tuple [a "write", list es] ∉ [effect] := by
    intro es mem
    simp only [List.mem_singleton] at mem
    subst mem
    simp [Internal, a] at internal
  have yieldSame : yieldRoom σ' = yieldRoom σ := by
    rw [yieldRoom_nowrite perform noWrite, yieldRoom_feed ctl, work]
  have changedSame : changedRoom σ' = changedRoom σ := by
    unfold changedRoom; rw [perform, ctl, work]; rfl
  have envSame : envRoom σ' = envRoom σ := by
    unfold envRoom; rw [work, dur, pend]
  unfold chainPot restPot
  rw [yieldSame, changedSame, envSame, work, ctl, perform, ctlRank_perform, ctlRank_feed act]
  exact Nat.le_refl _

theorem env_step {C : Int} {σ σ' : HostState} {t : Term} {events : List Term}
    (inv : InChain C σ) (land : ResidentBatch σ.durable events t)
    (same : σ'.working = σ.working ∧ σ'.durable = t ∧ σ'.pending = σ.pending ∧ σ'.control = σ.control) :
    chainPot C σ' ≤ chainPot C σ + envWeight C ∧ InChain C σ' := by
  obtain ⟨work, dur, pend, ctl⟩ := same
  obtain ⟨sid, ctlInv⟩ := inv
  refine ⟨?_, ⟨by rw [dur, work, batch_session land]; exact sid, by rw [ctl, work]; exact ctlInv⟩⟩
  have rest : restPot C σ' = restPot C σ := by
    unfold restPot yieldRoom changedRoom; rw [ctl, work]
  unfold chainPot
  rw [rest]
  have := envRoom_le σ'
  have : envWeight C * envRoom σ' ≤ envWeight C * 1 := Nat.mul_le_mul_left _ this
  omega

theorem refresh_step {C : Int} {σ σ' : HostState}
    (inv : InChain C σ) (clean : σ.pending = false)
    (same : σ'.working = σ.durable ∧ σ'.durable = σ.durable ∧ σ'.pending = σ.pending ∧ σ'.control = σ.control) :
    chainPot C σ' ≤ chainPot C σ ∧ InChain C σ' := by
  obtain ⟨work, dur, pend, ctl⟩ := same
  obtain ⟨sid, ctlInv⟩ := inv
  have inv' : InChain C σ' := by
    refine ⟨by rw [dur, work], ?_⟩
    rw [ctl, work]
    revert ctlInv
    cases σ.control with
    | feed m ev => intro h; exact h
    | perform m effs =>
      intro h
      obtain ⟨act, ceiling, internal, router, writes⟩ := h
      refine ⟨act, ceiling, internal, router, fun es mem => ?_⟩
      obtain ⟨pair, notBusy, s₀, shape, s₀sid⟩ := writes es mem
      exact ⟨pair, notBusy, s₀, shape, s₀sid.trans sid.symm⟩
    | idle => intro h; exact h
    | running m c => intro h; exact h
  refine ⟨?_, inv'⟩
  by_cases equal : σ.durable = σ.working
  · have rest : restPot C σ' = restPot C σ := by
      unfold restPot yieldRoom changedRoom; rw [ctl, work, equal]
    have env : envRoom σ' = envRoom σ := by
      unfold envRoom; rw [work, dur, pend, equal]
    unfold chainPot; rw [rest, env]; exact Nat.le_refl _
  · have room : envRoom σ = 1 := envRoom_one clean equal
    have clear : envRoom σ' = 0 := envRoom_zero_of (Or.inr (dur.trans work.symm))
    have := pot_jump (C := C) room clear
    omega

/-! ## Activation chains -/

def IsFeed : Control → Prop
  | .feed _ _ => True
  | _ => False

def IsPerform : Control → Prop
  | .perform _ _ => True
  | _ => False

open Classical in
/-- A host transition runs a kernel step: it leaves a `feed` control for a `perform` control. -/
noncomputable def kernelCount (σ σ' : HostState) : Nat := if IsFeed σ.control ∧ IsPerform σ'.control then 1 else 0

/-- An environment write label. -/
def HostLabel.isEnv : HostLabel → Bool
  | .env _ _ => true
  | _ => false

/-- The environment writes of a log. -/
def envCount (log : List HostLabel) : Nat := log.countP HostLabel.isEnv

theorem kernelCount_one {σ σ' : HostState} {m ev m' : Term} {effs : List Term}
    (feed : σ.control = .feed m ev) (ctl : σ'.control = .perform m' effs) : kernelCount σ σ' = 1 := by
  unfold kernelCount; rw [feed, ctl]; simp [IsFeed, IsPerform]

theorem kernelCount_perform {σ σ' : HostState} {m : Term} {effs : List Term}
    (ctl : σ.control = .perform m effs) : kernelCount σ σ' = 0 := by
  unfold kernelCount; rw [ctl]; simp [IsFeed]

theorem kernelCount_same {σ σ' : HostState} (ctl : σ'.control = σ.control) : kernelCount σ σ' = 0 := by
  unfold kernelCount
  rw [ctl]
  cases σ.control <;> simp [IsFeed, IsPerform]

theorem envCount_nil : envCount [] = 0 := rfl

theorem envCount_append (xs ys : List HostLabel) : envCount (xs ++ ys) = envCount xs + envCount ys := by
  simp [envCount, List.countP_append]

theorem idle_absurd {C : Int} {σ : HostState} (inv : InChain C σ) (idle : σ.control = .idle) : False := by
  have h := inv.2
  rw [idle] at h
  exact h

theorem running_absurd {C : Int} {σ : HostState} {m c : Term} (inv : InChain C σ)
    (running : σ.control = .running m c) : False := by
  have h := inv.2
  rw [running] at h
  exact h

/-- One host transition inside an activation chain: a kernel step drops the
potential by one, an environment write raises it by at most `envWeight`, and
no other transition raises it. -/
theorem chain_step {C : Int} {cfg : HostConfig} (present : RouterFactsPresent cfg)
    {σ σ' : HostState} {labels : List HostLabel}
    (inv : InChain C σ) (next : HostStep cfg σ labels σ') (chain : ChainControl σ'.control) :
    kernelCount σ σ' + chainPot C σ' ≤ chainPot C σ + envWeight C * envCount labels ∧ InChain C σ' := by
  have ctlInv := inv.2
  cases next with
  | enter idle => exact (idle_absurd inv idle).elim
  | request idle => exact (idle_absurd inv idle).elim
  | @«local» machine event machine' effects feed step noCommit =>
    obtain ⟨pot, inv'⟩ := plain_step (σ' := { σ with control := .perform machine' effects })
      inv feed step noCommit rfl chain rfl rfl (Or.inl rfl)
    rw [kernelCount_one feed rfl]
    exact ⟨by simp [envCount_nil]; omega, inv'⟩
  | commit feed clean first step land =>
    obtain ⟨pot, inv'⟩ := commit_step inv feed step land rfl chain rfl rfl (Or.inr ⟨clean, rfl⟩)
    rw [kernelCount_one feed rfl]
    exact ⟨by simp [envCount, HostLabel.isEnv]; omega, inv'⟩
  | reroute feed clean first step noCommit =>
    obtain ⟨pot, inv'⟩ := plain_step inv feed step noCommit rfl chain rfl rfl (Or.inr ⟨clean, rfl⟩)
    rw [kernelCount_one feed rfl]
    exact ⟨by simp [envCount_nil]; omega, inv'⟩
  | fenceCommit feed dirty step notSpeculative land cas =>
    obtain ⟨pot, inv'⟩ := commit_step inv feed step land rfl chain rfl rfl (Or.inl rfl)
    rw [kernelCount_one feed rfl]
    exact ⟨by simp [envCount, HostLabel.isEnv]; omega, inv'⟩
  | speculative => simp [ChainControl, a] at chain
  | speculativeFailed => simp [ChainControl] at chain
  | skip perform kind =>
    obtain ⟨pot, inv'⟩ := skip_step inv perform kind rfl chain ⟨rfl, rfl, rfl⟩
    rw [kernelCount_perform perform]
    exact ⟨by simp [envCount_nil]; omega, inv'⟩
  | write perform land =>
    obtain ⟨pot, inv'⟩ := write_step inv perform land rfl chain rfl rfl rfl
    rw [kernelCount_perform perform]
    exact ⟨by simp [envCount, HostLabel.isEnv]; omega, inv'⟩
  | reply perform answer =>
    obtain ⟨pot, inv'⟩ := reply_step present inv perform answer rfl chain ⟨rfl, rfl, rfl⟩
    rw [kernelCount_perform perform]
    exact ⟨by simp [envCount_nil]; omega, inv'⟩
  | record => simp [ChainControl, a] at chain
  | dispatch => simp [ChainControl] at chain
  | returned running => exact (running_absurd inv running).elim
  | planned perform =>
    rw [perform] at ctlInv
    obtain ⟨_, _, internal, _⟩ := ctlInv
    simp [Internal, a] at internal
  | materialize => simp [ChainControl] at chain
  | materializeRun => simp [ChainControl] at chain
  | fast idle => exact (idle_absurd inv idle).elim
  | stop => simp [ChainControl] at chain
  | fence idle => exact (idle_absurd inv idle).elim
  | refresh clean =>
    obtain ⟨pot, inv'⟩ := refresh_step (σ' := { σ with working := σ.durable, baseline := σ.durable }) inv clean
      ⟨rfl, rfl, rfl, rfl⟩
    rw [kernelCount_same (σ := σ) (σ' := { σ with working := σ.durable, baseline := σ.durable }) rfl]
    exact ⟨by simp [envCount_nil]; omega, inv'⟩
  | @env kind t events plan land =>
    obtain ⟨pot, inv'⟩ := env_step (σ' := { σ with durable := t }) inv land ⟨rfl, rfl, rfl, rfl⟩
    rw [kernelCount_same (σ := σ) (σ' := { σ with durable := t }) rfl]
    exact ⟨by simp [envCount, HostLabel.isEnv]; omega, inv'⟩
  | abort => simp [ChainControl] at chain
  | crash => simp [ChainControl] at chain
  | restart idle => exact (idle_absurd inv idle).elim

/-- A host run inside an activation chain. Every state after the first has
the control of an activation chain. `n` counts the transitions that run a
kernel step. -/
inductive ChainRun (cfg : HostConfig) : HostState → Nat → List HostLabel → HostState → Prop where
  | refl (σ : HostState) : ChainRun cfg σ 0 [] σ
  | step {σ₀ σ σ' : HostState} {n : Nat} {log labels : List HostLabel}
      (run : ChainRun cfg σ₀ n log σ) (next : HostStep cfg σ labels σ') (chain : ChainControl σ'.control) :
      ChainRun cfg σ₀ (n + kernelCount σ σ') (log ++ labels) σ'

theorem ChainRun.hostRun {cfg : HostConfig} {σ₀ σ : HostState} {n : Nat} {log : List HostLabel}
    (run : ChainRun cfg σ₀ n log σ) : HostRun cfg σ₀ log σ := by
  induction run with
  | refl => exact .refl _
  | step _ next _ ih => exact .step ih next

theorem chain_run_pot {C : Int} {cfg : HostConfig} (present : RouterFactsPresent cfg)
    {σ₀ σ : HostState} {n : Nat} {log : List HostLabel}
    (start : InChain C σ₀) (run : ChainRun cfg σ₀ n log σ) :
    n + chainPot C σ ≤ chainPot C σ₀ + envWeight C * envCount log ∧ InChain C σ := by
  induction run with
  | refl => exact ⟨by simp [envCount_nil], start⟩
  | step _ next chain ih =>
    obtain ⟨pot, inv⟩ := ih
    obtain ⟨pot', inv'⟩ := chain_step present inv next chain
    refine ⟨?_, inv'⟩
    rw [envCount_append, Nat.mul_add]
    omega

/-- The start of an activation chain: the host entered `{:activate, facts}` or
a fired wait timer with a ceiling fact of at most `C`. -/
theorem entry_inChain {C : Int} {σ : HostState} {ev : Term} (feed : σ.control = .feed nil ev)
    (entry : ChainEntry ev) (ceiling : integerValue (mkey (entryRound nil ev) "ceiling_ms") ≤ C)
    (sid : σ.durable.get (a "session_id") = σ.working.get (a "session_id")) : InChain C σ := by
  refine ⟨sid, ?_⟩
  rw [feed]
  exact Or.inr ⟨rfl, entry, ceiling⟩

/-- `activation_chain_bounded`: on the host model, an activation chain that
starts at an entry runs at most `chainBound C · (1 + e)` kernel steps, where
`e` counts the environment writes during the chain. Hypotheses: the host
answers the Router fact with a present value, and the ceiling fact of the
entry is at most `C`. Yields, wait extensions and changed waits need no
separate count: one yield per wait (the yield clears the wait), at most
`C / 1000` extensions per wait, and a changed wait only after another writer
changed the durable state. -/
theorem activation_chain_bounded {C : Int} {cfg : HostConfig} (present : RouterFactsPresent cfg)
    {σ₀ σ : HostState} {n : Nat} {log : List HostLabel}
    (start : InChain C σ₀) (run : ChainRun cfg σ₀ n log σ) :
    n ≤ chainBound C * (1 + envCount log) := by
  obtain ⟨pot, _⟩ := chain_run_pot present start run
  have := chainPot_le C σ₀
  unfold chainBound at this ⊢
  have : envWeight C * envCount log ≤ 2 * envWeight C * envCount log := by
    rw [Nat.mul_assoc]; omega
  rw [Nat.mul_add, Nat.mul_one]
  omega

/-! ## One session on the host model -/

/-- The three host states belong to one session. -/
def SameSession (σ : HostState) : Prop :=
  σ.working.get (a "session_id") = σ.durable.get (a "session_id") ∧
    σ.baseline.get (a "session_id") = σ.durable.get (a "session_id")

theorem sameSession_step {cfg : HostConfig} {σ σ' : HostState} {labels : List HostLabel}
    (next : HostStep cfg σ labels σ') (same : SameSession σ) : SameSession σ' := by
  obtain ⟨work, base⟩ := same
  cases next with
  | commit feed clean first step land => exact ⟨rfl, rfl⟩
  | reroute => exact ⟨rfl, rfl⟩
  | fenceCommit feed dirty step notSpeculative land cas => exact ⟨rfl, rfl⟩
  | speculative => exact ⟨rfl, rfl⟩
  | speculativeFailed => exact ⟨base, base⟩
  | write perform land =>
    refine ⟨?_, base⟩
    show _ = σ.durable.get _
    rw [batch_session land, work]
  | materialize perform plan land =>
    refine ⟨?_, base⟩
    show _ = σ.durable.get _
    rw [batch_session land, work]
  | materializeRun perform plan land =>
    refine ⟨?_, base⟩
    show _ = σ.durable.get _
    rw [batch_session land, work]
  | fast idle plan land =>
    refine ⟨?_, base⟩
    show _ = σ.durable.get _
    rw [batch_session land, work]
  | fence => exact ⟨rfl, rfl⟩
  | refresh => exact ⟨rfl, rfl⟩
  | env plan land =>
    refine ⟨?_, ?_⟩
    · show σ.working.get _ = _
      rw [batch_session land, work]
    · show σ.baseline.get _ = _
      rw [batch_session land, base]
  | abort => exact ⟨base, base⟩
  | crash => exact ⟨rfl, rfl⟩
  | restart => exact ⟨rfl, rfl⟩
  | _ => exact ⟨work, base⟩

theorem sameSession_run {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) (start : SameSession σ₀) : SameSession σ := by
  induction run with
  | refl => exact start
  | step _ next ih => exact sameSession_step next ih

theorem sameSession_init {σ : HostState} (init : HostInit σ) : SameSession σ := by
  obtain ⟨_, work, base, _⟩ := init
  exact ⟨by rw [work], by rw [base]⟩

/-- `activation_chain_after`: on a host run from `HostInit`, the host enters an
activation chain (`{:activate, facts}` or a fired wait timer) whose ceiling
fact is at most `C`. The chain that follows runs at most
`chainBound C · (1 + e)` kernel steps, where `e` counts the environment writes
during the chain. Hypothesis: the host answers the Router fact with a present
value. -/
theorem activation_chain_after {C : Int} {cfg : HostConfig} (present : RouterFactsPresent cfg)
    {σ₀ σ σ' : HostState} {log log' : List HostLabel} {n : Nat} {ev : Term}
    (init : HostInit σ₀) (before : HostRun cfg σ₀ log σ) (feed : σ.control = .feed nil ev)
    (entry : ChainEntry ev) (ceiling : integerValue (mkey (entryRound nil ev) "ceiling_ms") ≤ C)
    (chain : ChainRun cfg σ n log' σ') :
    n ≤ chainBound C * (1 + envCount log') := by
  have same := sameSession_run before (sameSession_init init)
  exact activation_chain_bounded present (entry_inChain feed entry ceiling same.1.symm) chain

/-! ## Internal chains outside the activation phases -/

/-- The rank drops at an internal step. -/
def DropStep (m out : Term) : Prop := Internal out → inRank (outMachine out) < inRank m

/-- A branch that runs a helper with a `PhaseOut` lemma: the rank drops. -/
macro "drop_leaf " m:term:max lem:term:max ph:str : tactic => `(tactic| (
  refine Sat.mono $lem (fun out po internal => ?_)
  obtain ⟨p, mem, outPhase⟩ := po internal
  have inPhase : mkey $m "phase" = b $ph := phase_of_beq ‹(_ == b $ph) = true›
  rw [inRank_of outPhase, inRank_of inPhase]
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at mem
  all_goals (rcases mem with h | h | h <;> subst_vars <;> simp (config := {decide := true}) [phaseRank, binary_key_beq])))

/-- A `continue` step on a machine outside the activation phases drops the
rank. The model-round phases have no re-entry. -/
theorem model_continue_drop {ask : Loop.Ask} {state m : Term} (outside : ¬ ActPhase m) :
    Sat (DropStep m) (Loop.stepWith ask state (.tuple [m, a "continue"])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  · drop_leaf m classify_out "classify"
  · exact (outside (Or.inl (phase_of_beq ‹(_ == b "activation") = true›))).elim
  · exact (outside (Or.inr (Or.inr (Or.inr (phase_of_beq ‹(_ == b "timeout") = true›))))).elim
  · unfold DropStep; loop_unfold; simp [Internal]
  · drop_leaf m outputCommitted_out "output_committed"
  · drop_leaf m modelFailed_out "model_failed"
  · drop_leaf m guardNotice_out "guard_notice"
  · drop_leaf m noticeCleanup_out "notice_cleanup"
  · unfold DropStep; loop_unfold; simp [Internal]
  · have inPhase : mkey m "phase" = b "notice_committed" := phase_of_beq ‹(_ == b "notice_committed") = true›
    generalize hfs : (native_decl% "VerifiedKernel.Session.Loop.finalStop" : Term → Term × List Term) m = fs
    obtain ⟨stopped, effs⟩ := fs
    rcases finalStop_cases hfs with ⟨outPhase, rfl⟩ | rfl
    · intro _
      loop_unfold
      rw [outMachine_tuple, inRank_of outPhase, inRank_of inPhase]
      simp [phaseRank, binary_key_beq]
    · unfold DropStep; loop_unfold; simp [Internal]
  · drop_leaf m guardOutcome_out "guard_outcome"
  · drop_leaf m continuation_out "continuation"
  · unfold DropStep; loop_unfold; simp [Internal]
  · unfold DropStep; loop_unfold; simp [Internal]

/-- A `fact` answer on a machine outside the activation phases fails: only the
`router` and `busy` phases take a fact. -/
theorem model_fact_none {ask : Loop.Ask} {state m v : Term} (outside : ¬ ActPhase m) :
    Sat (fun _ => False) (Loop.stepWith ask state (.tuple [m, .tuple [a "fact", v]])) := by
  unfold Loop.stepWith
  dsimp only
  apply Sat.bind
  intro sid _ _ _
  simp only [a]
  sat_walk
  · exact (outside (Or.inr (Or.inl (phase_of_beq ‹(_ == b "router") = true›)))).elim
  · exact (outside (Or.inr (Or.inr (Or.inl (phase_of_beq ‹(_ == b "busy") = true›))))).elim

/-- `model_chain_bounded`: an internal chain whose steps after the first read
machines outside the activation phases has at most 4 steps, for any oracle.
With `activation_chain_bounded`, no internal chain needs a count of
re-entries: the activation phases and the model-round phases do not mix in
one chain (their step outputs keep their own phases). -/
theorem model_step_drop {ask : Loop.Ask} {t : StepRec} (runs : t.Runs ask) (internal : Internal t.out)
    (answer : t.event = a "continue" ∨ ∃ v, t.event = .tuple [a "fact", v]) (outside : ¬ ActPhase t.machine) :
    inRank (outMachine t.out) < inRank t.machine := by
  obtain ⟨j, j', run⟩ := runs
  rcases answer with same | ⟨v, same⟩
  · rw [same] at run
    exact Sat.use (model_continue_drop outside) run internal
  · rw [same] at run
    exact (Sat.use (model_fact_none outside) run).elim

theorem drop_chain {ask : Loop.Ask} :
    ∀ {steps : List StepRec} {s : StepRec}, steps.head? = some s → InternalChain ask steps →
      (s.event = a "continue" ∨ ∃ v, s.event = .tuple [a "fact", v]) →
      (∀ t ∈ steps, ¬ ActPhase t.machine) → steps.length ≤ inRank s.machine
  | [], _, head, _, _, _ => by cases head
  | [t], s, head, chain, answer, outside => by
    cases head
    obtain ⟨runs, internal⟩ := chain
    have := model_step_drop runs internal answer (outside t List.mem_cons_self)
    simp only [List.length_singleton]
    omega
  | t :: u :: rest, s, head, chain, answer, outside => by
    cases head
    obtain ⟨runs, internal, machine, follows, chain'⟩ := chain
    have drop := model_step_drop runs internal answer (outside t List.mem_cons_self)
    have ih := drop_chain (steps := u :: rest) (s := u) rfl chain' (follows_answer follows)
      (fun x mem => outside x (List.mem_cons_of_mem _ mem))
    rw [machine] at ih
    simp only [List.length_cons] at ih ⊢
    omega

/-- `model_chain_bounded`: an internal chain whose steps after the first read
machines outside the activation phases has at most 4 steps, for any oracle.
The model-round phases have no re-entry. -/
theorem model_chain_bounded {ask : Loop.Ask} {s : StepRec} {rest : List StepRec}
    (chain : InternalChain ask (s :: rest)) (outside : ∀ t ∈ rest, ¬ ActPhase t.machine) :
    (s :: rest).length ≤ 4 := by
  cases rest with
  | nil => simp
  | cons u rest =>
    obtain ⟨_, _, _, follows, chain'⟩ := chain
    have len := drop_chain (steps := u :: rest) (s := u) rfl chain' (follows_answer follows) outside
    have le := inRank_le u.machine
    simp only [List.length_cons] at len ⊢
    omega

end VerifiedKernel.Session.Loop.Budget
