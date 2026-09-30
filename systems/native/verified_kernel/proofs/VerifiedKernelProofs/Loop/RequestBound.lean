import VerifiedKernelProofs.Loop.Host

/-! # Model requests need a granted round (property C)

On the host model of `Host.lean`, a model request is the entry of a
`model_response` or `model_failure` (`HostStep.request`). It needs a granted
round, and it uses the grant. Three host transitions grant a round:

* `materializeRun`: the activation step returned `{:materialize, mode}` and
  `plan_revision` returned `run` (the driver's `{:plan, mode}`, then `activate`);
* `fast`: the fast activation of the async-terminal continuation, which runs
  right after a background completion commit;
* `stop` with the outcome `context_overflow`: the host compacts and starts one
  round (the driver's `compact_round`).

`requests_le_grants` counts them: each model request uses one grant.

`requests_without_credits` and `requests_not_bounded` show the limit of this
model. The model leaves the fast activation and host failures free. So no
bound on model requests in fresh input, background completions and wait
expiries alone holds on this model. -/

namespace VerifiedKernel.Session.LoopProof
open Data
set_option Elab.async false

/-- A label that grants one model round. -/
def HostLabel.grants : HostLabel → Bool
  | .grant _ => true
  | .stop outcome => outcome == a "context_overflow"
  | _ => false

/-- The ghost grant as a number. -/
def grantedCount (σ : HostState) : Nat := if σ.granted then 1 else 0

theorem requests_le_grants_step {cfg : HostConfig} {σ σ' : HostState} {labels : List HostLabel}
    (next : HostStep cfg σ labels σ') :
    labels.countP HostLabel.modelRequest + grantedCount σ' ≤ labels.countP HostLabel.grants + grantedCount σ := by
  cases next with
  | enter idle ungated => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount, ungated]
  | request idle model granted =>
    simp [HostLabel.modelRequest, HostLabel.grants, grantedCount, model, granted]
  | materializeRun => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]
  | fast => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]
  | @stop machine outcome perform =>
    simp only [List.countP_cons, List.countP_nil, HostLabel.modelRequest, HostLabel.grants, grantedCount]
    by_cases over : (outcome == a "context_overflow") = true
    · simp only [over, Bool.or_true]; cases σ.granted <;> simp
    · simp only [Bool.not_eq_true] at over
      simp only [over, Bool.or_false]; cases σ.granted <;> simp
  | crash => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]
  | speculative => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]
  | speculativeFailed => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]
  | _ => simp [HostLabel.modelRequest, HostLabel.grants, grantedCount]

/-- `requests_le_grants`: in any host run, the model requests are at most the
grants, plus one for a round that was granted at the start. -/
theorem requests_le_grants {cfg : HostConfig} {σ₀ σ : HostState} {log : List HostLabel}
    (run : HostRun cfg σ₀ log σ) :
    log.countP HostLabel.modelRequest + grantedCount σ ≤ log.countP HostLabel.grants + grantedCount σ₀ := by
  induction run with
  | refl => simp
  | step _ next ih =>
    have := requests_le_grants_step next
    simp only [List.countP_append]
    omega

/-! ## What the credits must cover

The host model leaves the fast activation and host failures free. A host
that repeats `fast`, one model request, and a failed storage write makes one
model request per cycle. No input, background completion or wait expiry
occurs. Thus a bound in those credits alone does not hold on this model: the
bound must count faults (`failed`, `crash`) and fast activations, or a host
contract must restrict them (`requests_without_credits`). -/

/-- A host that grants a fast activation at any time. -/
def freeFastHost : HostConfig where
  record := fun _ _ _ => False
  tools := fun _ _ => False
  store := fun _ _ _ _ => False
  activation := fun _ _ _ _ => False
  fast := fun _ _ => True
  fact := fun _ _ => False
  env := fun _ _ _ => False
  restart := fun _ _ => False

/-- An idle host whose revision is the durable state `.map []`. -/
def quietState : HostState :=
  { durable := .map [], working := .map [], baseline := .map [], pending := false, calls := nil,
    control := .idle, granted := false }

/-- A model-failure entry. -/
def failureEntry : Term := .tuple [a "model_failure", .map [], .map []]

/-- One cycle: a fast grant, one model request, and a failed write. -/
theorem fault_cycle :
    HostRun freeFastHost quietState [.activate [], .grant (a "fast"), .enter failureEntry, .failed] quietState := by
  have fast := HostStep.fast (cfg := freeFastHost) (σ := quietState) (t := .map []) (events := []) rfl trivial
    (WorkConservation.ResidentBatch.nil _)
  have request := HostStep.request (cfg := freeFastHost) (event := failureEntry)
    (σ := { quietState with working := .map [], pending := true, granted := true }) rfl rfl rfl
  have abort := HostStep.abort (cfg := freeFastHost)
    (σ := { ({ quietState with working := .map [], pending := true, granted := true } : HostState) with
      control := .feed nil failureEntry, granted := false }) (by simp)
  have run := HostRun.step (HostRun.step (HostRun.single fast) request) abort
  simpa [quietState] using run

/-- A label that the natural credit set counts: fresh input, a background
completion, or a fired wait timer. -/
def HostLabel.naturalCredit (label : HostLabel) : Bool :=
  label.freshInput || label.asyncCompletion || label.waitExpired

/-- `requests_without_credits`: on the host model, `n` model requests can
occur with no fresh input, no background completion and no wait expiry. -/
theorem requests_without_credits (n : Nat) :
    ∃ log, HostInit quietState ∧ HostRun freeFastHost quietState log quietState ∧
      log.countP HostLabel.modelRequest = n ∧ log.countP HostLabel.naturalCredit = 0 := by
  induction n with
  | zero => exact ⟨[], ⟨rfl, rfl, rfl, rfl⟩, HostRun.refl _, rfl, rfl⟩
  | succ n ih =>
    obtain ⟨log, init, run, requests, credits⟩ := ih
    refine ⟨log ++ [.activate [], .grant (a "fast"), .enter failureEntry, .failed], init,
      run.trans fault_cycle, ?_, ?_⟩
    · simp [List.countP_append, requests, HostLabel.modelRequest, failureEntry, modelEntry]
    · simp [List.countP_append, credits, HostLabel.naturalCredit, HostLabel.freshInput, HostLabel.asyncCompletion,
        HostLabel.waitExpired, failureEntry]

/-- The trace-level bound with the natural credits: in every host run from an
initial state, the model requests are at most `B` for each credit, plus `B`. -/
def RequestsBounded (cfg : HostConfig) (B : Nat) : Prop :=
  ∀ σ₀ log σ, HostInit σ₀ → HostRun cfg σ₀ log σ →
    log.countP HostLabel.modelRequest ≤ B * (1 + log.countP HostLabel.naturalCredit)

/-- `requests_not_bounded`: no `B` bounds the model requests of every host run
in the natural credits alone. -/
theorem requests_not_bounded (B : Nat) : ¬ RequestsBounded freeFastHost B := by
  intro bound
  obtain ⟨log, init, run, requests, credits⟩ := requests_without_credits (B + 1)
  have := bound _ _ _ init run
  rw [requests, credits] at this
  omega

end VerifiedKernel.Session.LoopProof
