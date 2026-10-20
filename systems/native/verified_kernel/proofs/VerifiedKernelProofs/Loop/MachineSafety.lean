import VerifiedKernelProofs.Loop.Shape
import VerifiedKernelProofs.Loop.QueryAnswers
import VerifiedKernelProofs.Session.WorkRevisionExpiry
import VerifiedKernelProofs.Session.WorkOrdinaryKinds

/-! # Loop machine safety

The machine invariant of `WorkEmbedding`. It depends only on the loop shape and the ordinary
event kinds, so it builds while the Session producer proofs build. -/

namespace VerifiedKernel.Session.LoopProof
open Data
open WorkConservation
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem list_ne_nil (xs : List Term) : list xs ≠ nil := fun same => Term.noConfusion same

theorem list_inj {xs ys : List Term} (same : list xs = list ys) : xs = ys := by
  injection same

theorem single_raw {e : Term} (safe : RawOrdinary e) : RawOrdinaryBatch [e] := by
  intro x member
  rw [List.mem_singleton.mp member]
  exact safe

theorem wait_timeout_ordinary {state args ev : Term} {journal rest : List Term}
    (call : Command.waitTimeout state args journal = .ok (ev, rest)) (present : (ev == nil) = false) :
    OrdinaryBatch [ev] := by
  rcases wait_timeout_shape call with rfl | ⟨routed, kind⟩
  · exact absurd present (by decide)
  · intro e member
    rw [List.mem_singleton.mp member]
    exact ⟨routed.1, by rw [kind]; simp +decide [OrdinaryKind, b, Term.text]⟩

/-! ## The machine invariant

The host holds the loop machine between steps. The only machine field that a
commit carries unchanged is the timeout event of a `wait_timeout` entry.
Every machine that the kernel returns keeps that event ordinary. -/

theorem single_raw_inv {e : Term} (safe : RawOrdinaryBatch [e]) : RawOrdinary e := safe e (by simp)

theorem raw_ordinary_non_map {v : Term} (plain : v.isMap = false) : RawOrdinary v := by
  intro normalized journal rest call
  unfold shallowStringify at call
  obtain ⟨xs, _, read, _⟩ := bind_ok call
  cases v <;> simp_all [entries, Term.isMap, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift,
    Functor.map, Except.map]

/-- The carried timeout event of a machine whose entry is `wait_timeout` is ordinary. -/
def MachineSafe (machine : Term) : Prop :=
  mkey machine "entry" = b "wait_timeout" → RawOrdinary (mkey machine "timeout_event")

def SafeOut (out : Term) : Prop := ∃ machine effects, out = .tuple [machine, list effects] ∧ MachineSafe machine

theorem mkey_map_cons (k k' : String) (v : Term) (rest : List (Term × Term)) :
    mkey (Term.map ((b k, v) :: rest)) k' = if k = k' then v else mkey (Term.map rest) k' := by
  simp only [mkey_eq_get, Term.get, List.find?_cons, binary_key_beq]
  by_cases same : k = k'
  · simp [same]
  · have ne : (k == k') = false := by simpa using same
    simp [ne, same]

theorem mkey_map_nil (k : String) : mkey (Term.map []) k = nil := rfl

theorem safe_nil_entry {m : Term} (absent : mkey m "entry" = nil) : MachineSafe m := by
  intro he
  rw [absent] at he
  cases he

syntax "safe_norm" : tactic
macro_rules
  | `(tactic| safe_norm) => `(tactic|
    (try simp (disch := decide) only [loop_key_mkey, loop_phase_put, mkey_put_same, mkey_put_other,
      mkey_map_cons, mkey_map_nil, ↓reduceIte] at *))

syntax "close_safe" : tactic
macro_rules
  | `(tactic| close_safe) => `(tactic|
    (refine ⟨_, _, rfl, ?_⟩
     unfold MachineSafe
     try split
     all_goals
       safe_norm
       first
         | assumption
         | (intro he; cases he)
         | (intro _; exact raw_ordinary_non_map rfl)))

theorem guardOutcome_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% guardOutcome) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop guardOutcome
  run_split
  all_goals close_safe

theorem park_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% park) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop park
  run_split
  all_goals first
    | close_safe

theorem guardNotice_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% guardNotice) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop guardNotice
  unfold_loop finalStop
  run_split
  all_goals first
    | close_safe

theorem noticeCleanup_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% noticeCleanup) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop noticeCleanup
  run_split
  all_goals first
    | close_safe

theorem finalize_safe {state m out : Term} {terminal : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% finalize) Loop.queryAsk state m terminal j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop finalize
  run_split
  all_goals first
    | close_safe

theorem finalRecord_safe {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% finalRecord) Loop.queryAsk state m record j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop finalRecord
  run_split
  all_goals first
    | close_safe
    | exact finalize_safe safe h
    | exact finalize_safe safe prior

theorem modelFailure_safe {state m out : Term} {info : Term} {recover : Bool} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% modelFailure) Loop.queryAsk state m info recover j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop modelFailure
  run_split
  all_goals first
    | close_safe

theorem modelFailed_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% modelFailed) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop modelFailed
  run_split
  all_goals first
    | close_safe

theorem toolTurn_safe {m out : Term} {outcome : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% toolTurn) m outcome j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop toolTurn
  run_split
  all_goals first
    | close_safe

theorem intentRecord_safe {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% intentRecord) state m record j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop intentRecord
  run_split
  all_goals first
    | close_safe
    | exact toolTurn_safe safe h
    | exact toolTurn_safe safe prior
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) _ _ _ _ = _)
       close_safe)

theorem toolsDone_safe {state m out : Term} {results async : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% toolsDone) Loop.queryAsk state m results async j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop toolsDone
  run_split
  all_goals first
    | close_safe
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       close_safe)

theorem resultsStored_safe {state m out : Term} {events hwm base stored : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% resultsStored) Loop.queryAsk state m events hwm base stored j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop resultsStored
  run_split
  all_goals first
    | close_safe

theorem safe_after_park {next parked : Term} {prefix_ : List Term}
    (parkOut : SafeOut (.tuple [next, parked])) : SafeOut (.tuple [next, list (prefix_ ++ wrap parked)]) := by
  obtain ⟨m, effs, same, safe⟩ := parkOut
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  obtain ⟨rfl, _⟩ := same
  exact ⟨_, _, rfl, safe⟩

theorem outputCommitted_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% outputCommitted) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop outputCommitted
  run_split
  all_goals first
    | close_safe
    | exact safe_after_park (park_safe safe' prior)

theorem continuation_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% continuation) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop continuation
  run_split
  all_goals try (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _))
  all_goals first
    | close_safe
    | (refine safe_after_park (park_safe ?_ prior)
       unfold MachineSafe
       safe_norm
       exact safe)

theorem expire_safe {state m busy out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% expire) state m busy j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop expire
  run_split
  all_goals try split_decide
  all_goals run_split
  all_goals close_safe

theorem expireEntry_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% expireEntry) state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold_loop expireEntry
  run_split
  all_goals first
    | close_safe
    | (refine expire_safe ?_ h
       unfold MachineSafe
       safe_norm
       exact safe)

theorem activation_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% activation) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop activation
  run_split
  all_goals first
    | close_safe
    | (refine expireEntry_safe ?_ h
       unfold MachineSafe
       safe_norm
       exact safe)

theorem timeoutEntry_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% timeoutEntry) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  unfold MachineSafe at safe
  unfold_loop timeoutEntry
  run_split
  all_goals first
    | close_safe
    | (refine expireEntry_safe ?_ h
       unfold MachineSafe
       safe_norm
       intro _
       have call := (hyp% Loop.queryAsk state "wait_timeout_event" _ _ = _)
       rw [QueryAnswers.wait_timeout] at call
       exact single_raw_inv (wait_timeout_ordinary call (not_true_false ‹_›)).raw)

theorem classify_safe {state m out : Term} {j j' : List Term} (safe : MachineSafe m)
    (h : (loop% classify) Loop.queryAsk state m j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  open_classify
  -- Select the helper lemma by the execution head. A failed `exact` against another helper
  -- unfolds both helper bodies before it fails.
  all_goals first
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalize"; refine finalize_safe ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_safe ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"; refine modelFailure_safe ?_ h)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.finalize"; refine finalize_safe ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_safe ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_safe ?_ prior)
  all_goals first
    | exact safe'
    | (unfold MachineSafe
       safe_norm
       exact safe)

theorem step_safe_out {state machine event out : Term} {j j' : List Term} (safe : MachineSafe machine)
    (h : Loop.stepWith Loop.queryAsk state (.tuple [machine, event]) j = .ok (out, j')) : SafeOut out := by
  have safe' := safe
  unfold MachineSafe at safe
  unfold Loop.stepWith at h
  unfold_loop finalStop
  run_split
  all_goals first
    | (execution_head_is h "Pure.pure"; close_safe)
    | close_safe
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalRecord"
       exact finalRecord_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.intentRecord"
       exact intentRecord_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolsDone"
       exact toolsDone_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.resultsStored"
       exact resultsStored_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.expire"
       exact expire_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.classify"
       exact classify_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.outputCommitted"
       exact outputCommitted_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailed"
       exact modelFailed_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.noticeCleanup"
       exact noticeCleanup_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardOutcome"
       exact guardOutcome_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.continuation"
       exact continuation_safe safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       refine guardNotice_safe ?_ h
       first
         | exact safe'
         | (refine safe_nil_entry ?_
            safe_norm
            simp))
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_safe (safe_nil_entry ?_) h
       safe_norm
       simp)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       refine activation_safe ?_ h
       first
         | exact safe'
         | (intro he
            safe_norm
            simp only [↓reduceIte, show ("round" = "entry") = False from by decide] at he
            exact absurd he (binary_ne (by decide)))
         | (unfold MachineSafe
            safe_norm
            exact safe))
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       refine timeoutEntry_safe ?_ h
       first
         | exact safe'
         | (intro _
            refine raw_ordinary_non_map ?_
            safe_norm
            simp [nil, Term.isMap]))

/-- The kernel keeps every machine it returns safe: a carried timeout event is
ordinary. -/
theorem step_machine_safe {state machine event machine' : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects) (safe : MachineSafe machine) :
    MachineSafe machine' := by
  obtain ⟨j, j', h⟩ := h
  obtain ⟨m, effs, same, safeOut⟩ := step_safe_out safe h
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  rw [same.1]
  exact safeOut

/-- The machine before the first event is safe. -/
theorem initial_machine_safe : MachineSafe nil := fun he => Term.noConfusion he

/-- Machines that the host passes back unchanged, starting from `nil`. This is
the machine-integrity assumption: the host never edits a loop machine. -/
inductive LoopChain : Term → Prop
  | initial : LoopChain nil
  | step {state machine event machine' : Term} {effects : List Term}
      (prior : LoopChain machine) (h : StepOK Loop.queryAsk state machine event machine' effects) :
      LoopChain machine'

theorem LoopChain.safe {machine : Term} (chain : LoopChain machine) : MachineSafe machine := by
  induction chain with
  | initial => exact initial_machine_safe
  | step _ h ih => exact step_machine_safe h ih

end VerifiedKernel.Session.LoopProof
