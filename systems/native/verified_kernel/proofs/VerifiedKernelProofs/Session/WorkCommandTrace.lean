import VerifiedKernelProofs.Session.DurableConfirmation
import VerifiedKernelProofs.Session.WorkInput

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace CommandExecution
open DurableConfirmation
set_option maxHeartbeats 1000000
set_option Elab.async false

inductive Trace : Term → List (Term × Result) → Term → Prop where
  | done (value) : Trace value [] value
  | resume {state request continuation result next final j r effects}
      (call : Command.resume state (.tuple [continuation, Result.wire result]) j = .ok (next, r))
      (tail : Trace next effects final) :
      Trace (.tuple [a "perform", request, continuation]) ((request, result) :: effects) final

theorem output_perform {events request token : Term} {phase : Phase}
    (h : output events phase = .tuple [a "perform", request, token]) :
    Awaiting phase ∧ token = continuation events phase ∧
      (phase = .fence → request = a "durable_fence") := by
  cases phase <;> simp only [output, Command.writeInput, Command.perform, Command.finish,
    continuation, a, b, list, Term.tuple.injEq, List.cons.injEq, and_true, true_and] at h ⊢
  · exact ⟨trivial, h.2.symm, by intro impossible; cases impossible⟩
  · exact ⟨trivial, h.2.symm, fun _ => h.1.symm⟩
  · exact ⟨trivial, h.2.symm, by intro impossible; cases impossible⟩
  · simp at h
  · simp at h

theorem advance_fence_source {s : Monitor} {request : Term} {result : Result}
    (requestIsFence : s.phase = .fence → request = a "durable_fence")
    (fenced : (advance s result).fences = 1) :
    s.fences = 1 ∨ (request, result) = (a "durable_fence", Result.ok) := by
  cases phase : s.phase <;> cases result <;>
    simp only [advance, phase, Nat.add_zero] at fenced
  all_goals first
    | exact Or.inl fenced
    | exact Or.inr (by rw [requestIsFence phase])

theorem trace_monitor {initial final events : Term} {effects : List (Term × Result)}
    (trace : Trace initial effects final) {s : Monitor}
    (initialOutput : initial = output events s.phase) (safe : Safe s) :
    ∃ next, final = output events next.phase ∧ Safe next ∧
      (next.fences = 1 → s.fences = 1 ∨ (a "durable_fence", Result.ok) ∈ effects) := by
  induction trace generalizing s with
  | done value => exact ⟨s, initialOutput, safe, fun same => Or.inl same⟩
  | @resume state request token result next final j r effects call tail ih =>
    obtain ⟨waiting, tokenRead, requestIsFence⟩ := output_perform initialOutput.symm
    rw [tokenRead, resume_refines state events s.phase result waiting] at call
    have nextOutput := pure_ok call
    obtain ⟨last, finalOutput, lastSafe, fences⟩ := ih nextOutput (advance_safe s result safe)
    refine ⟨last, finalOutput, lastSafe, ?_⟩
    intro finalFence
    rcases fences finalFence with currentFence | laterFence
    · rcases advance_fence_source requestIsFence currentFence with previous | thisFence
      · exact Or.inl previous
      · exact Or.inr (List.mem_cons.mpr (Or.inl thisFence.symm))
    · exact Or.inr (List.mem_cons_of_mem _ laterFence)

theorem output_confirmation_fenced {events final : Term} {s : Monitor}
    (value : final = output events s.phase) (safe : Safe s)
    (confirmed : final = Command.perform (.tuple [a "notify", b "input_accepted", events]) (b "input_notified") ∨
      final = Command.finish (.tuple [a "ok", a "committed"])) : s.fences = 1 := by
  rw [value] at confirmed
  cases phase : s.phase <;>
    simp [output, Command.writeInput, Command.perform, Command.finish, a] at confirmed
  all_goals simp_all [Safe, output, Command.writeInput, Command.perform, Command.finish, a, b, nil, list, Term.text]

theorem write_trace_confirmation {events final : Term} {effects : List (Term × Result)}
    (trace : Trace (Command.writeInput events) effects final)
    (confirmed : final = Command.perform (.tuple [a "notify", b "input_accepted", events]) (b "input_notified") ∨
      final = Command.finish (.tuple [a "ok", a "committed"])) :
    (a "durable_fence", Result.ok) ∈ effects := by
  obtain ⟨last, value, safe, fences⟩ := trace_monitor trace (s := {}) rfl initial_safe
  rcases fences (output_confirmation_fenced value safe confirmed) with impossible | found
  · cases impossible
  · exact found

theorem return_trace {result checkpoint final : Term} {effects : List (Term × Result)}
    (trace : Trace (Command.finish result checkpoint) effects final) :
    effects = [] ∧ final = Command.finish result checkpoint := by
  generalize startRead : Command.finish result checkpoint = start at trace
  cases trace with
  | done => exact ⟨rfl, rfl⟩
  | resume call tail => simp [Command.finish, a] at startRead

theorem duplicate_trace {final : Term} {effects : List (Term × Result)}
    (trace : Trace Command.duplicateInput effects final) :
    (effects = [] ∧ final = Command.duplicateInput) ∨
    (effects = [(a "durable_fence", Result.ok)] ∧ final = Command.finish (.tuple [a "ok", a "duplicate"])) ∨
    ∃ reason, effects = [(a "durable_fence", Result.error reason)] ∧
      final = Command.finish (.tuple [a "error", reason]) := by
  generalize initial : Command.duplicateInput = start at trace
  cases trace with
  | done => exact Or.inl ⟨rfl, rfl⟩
  | @resume state request token result next final j r effects call tail =>
    have same : request = a "durable_fence" ∧ token = b "input_duplicate_fenced" := by
      simpa only [Command.duplicateInput, Command.perform, Term.tuple.injEq,
        List.cons.injEq, and_true, true_and] using initial.symm
    rcases same with ⟨rfl, rfl⟩
    cases result with
    | ok =>
      change (pure (Command.finish (.tuple [a "ok", a "duplicate"])) : KernelM Term) j = .ok (next, r) at call
      rw [pure_ok call] at tail
      obtain ⟨rfl, finalRead⟩ := return_trace tail
      exact Or.inr (Or.inl ⟨rfl, finalRead⟩)
    | error reason =>
      change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
      rw [pure_ok call] at tail
      obtain ⟨rfl, finalRead⟩ := return_trace tail
      exact Or.inr (Or.inr ⟨reason, rfl, finalRead⟩)

theorem duplicate_confirmation_fenced {final : Term} {effects : List (Term × Result)}
    (trace : Trace Command.duplicateInput effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "duplicate"])) :
    effects = [(a "durable_fence", Result.ok)] := by
  rcases duplicate_trace trace with ⟨_, finalRead⟩ | ⟨effectsRead, _⟩ | ⟨reason, _, finalRead⟩
  · rw [finalRead] at confirmed
    simp [Command.duplicateInput, Command.perform, Command.finish, a] at confirmed
  · exact effectsRead
  · rw [finalRead] at confirmed
    simp [Command.finish, a] at confirmed

theorem input_start_trace_confirmation {start final : Term} {batch : List Term}
    {effects : List (Term × Result)} (started : InputStart start batch)
    (trace : Trace start effects final)
    (confirmed : final = Command.perform (.tuple [a "notify", b "input_accepted", list batch]) (b "input_notified") ∨
      final = Command.finish (.tuple [a "ok", a "committed"])) :
    (a "durable_fence", Result.ok) ∈ effects := by
  rcases started with rfl | ⟨operation, metadata, workspace, billing, rfl⟩
  · exact write_trace_confirmation trace confirmed
  · cases trace with
    | done => simp [Command.perform, Command.finish, a] at confirmed
    | @resume state request token result next final j r effects call tail =>
      cases result with
      | ok =>
        change (pure (Command.writeInput (list batch)) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        exact List.mem_cons_of_mem _ (write_trace_confirmation tail confirmed)
      | error reason =>
        change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        rw [(return_trace tail).2] at confirmed
        simp [Command.perform, Command.finish, a] at confirmed

theorem input_command_committed_has_fence {s args result final : Term} {j r : List Term}
    {effects : List (Term × Result)}
    (input : Command.input s args j = .ok (result, r))
    (trace : Trace result effects final)
    (committed : final = Command.finish (.tuple [a "ok", a "committed"])) :
    ∃ batch, InputStart result batch ∧ (a "durable_fence", Result.ok) ∈ effects := by
  rcases input_start input with duplicate | saturated | invalid | ⟨batch, started, _, _⟩
  · rw [duplicate] at trace
    rcases duplicate_trace trace with ⟨_, finalRead⟩ | ⟨_, finalRead⟩ | ⟨reason, _, finalRead⟩
    all_goals rw [finalRead] at committed
    all_goals simp [Command.duplicateInput, Command.perform, Command.finish, a] at committed
  · rw [saturated] at trace
    rw [(return_trace trace).2] at committed
    simp [Command.finish, a] at committed
  · rw [invalid] at trace
    rw [(return_trace trace).2] at committed
    simp [Command.finish, a] at committed
  · exact ⟨batch, started, input_start_trace_confirmation started trace (Or.inr committed)⟩

theorem output_notification_batch {events notified : Term} {phase : Phase}
    (h : output events phase = Command.perform
      (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) : notified = events := by
  cases phase <;> simp_all [output, Command.writeInput, Command.perform, Command.finish, a, b, nil, list, Term.text]

theorem write_trace_notification {events notified final : Term} {effects : List (Term × Result)}
    (trace : Trace (Command.writeInput events) effects final)
    (notification : final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) :
    notified = events ∧ (a "durable_fence", Result.ok) ∈ effects := by
  obtain ⟨last, value, safe, fences⟩ := trace_monitor trace (s := {}) rfl initial_safe
  have batch := output_notification_batch (value.symm.trans notification)
  exact ⟨batch, write_trace_confirmation trace (Or.inl (by rw [← batch]; exact notification))⟩

theorem input_start_trace_notification {start final notified : Term} {batch : List Term}
    {effects : List (Term × Result)} (started : InputStart start batch)
    (trace : Trace start effects final)
    (notification : final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) :
    notified = list batch ∧ (a "durable_fence", Result.ok) ∈ effects := by
  rcases started with rfl | ⟨operation, metadata, workspace, billing, rfl⟩
  · exact write_trace_notification trace notification
  · cases trace with
    | done => simp [Command.perform, a] at notification
    | @resume state request token result next final j r effects call tail =>
      cases result with
      | ok =>
        change (pure (Command.writeInput (list batch)) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        obtain ⟨batch, fenced⟩ := write_trace_notification tail notification
        exact ⟨batch, List.mem_cons_of_mem _ fenced⟩
      | error reason =>
        change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        rw [(return_trace tail).2] at notification
        simp [Command.perform, Command.finish, a] at notification

theorem input_command_notification_has_fence {s args result final notified : Term} {j r : List Term}
    {effects : List (Term × Result)}
    (input : Command.input s args j = .ok (result, r))
    (trace : Trace result effects final)
    (notification : final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) :
    ∃ batch, InputStart result batch ∧ notified = list batch ∧ (a "durable_fence", Result.ok) ∈ effects := by
  rcases input_start input with duplicate | saturated | invalid | ⟨batch, started, _, _⟩
  · rw [duplicate] at trace
    rcases duplicate_trace trace with ⟨_, finalRead⟩ | ⟨_, finalRead⟩ | ⟨reason, _, finalRead⟩
    all_goals rw [finalRead] at notification
    all_goals simp [Command.duplicateInput, Command.perform, Command.finish, a] at notification
  · rw [saturated] at trace
    rw [(return_trace trace).2] at notification
    simp [Command.perform, Command.finish, a] at notification
  · rw [invalid] at trace
    rw [(return_trace trace).2] at notification
    simp [Command.perform, Command.finish, a] at notification
  · exact ⟨batch, started, input_start_trace_notification started trace notification⟩

/-- A confirmed write trace starts with this exact batch, then its successful fence. -/
theorem write_trace_confirmation_prefix {events final : Term} {effects : List (Term × Result)}
    (trace : Trace (Command.writeInput events) effects final)
    (confirmed : final = output events .notify ∨ final = output events .done) :
    ∃ rest, effects = (.tuple [a "write", events, list []], Result.ok) ::
      (a "durable_fence", Result.ok) :: rest := by
  cases trace with
  | done => simp [output, Command.writeInput, Command.perform, Command.finish, a] at confirmed
  | @resume state request token result next final j r effects call tail =>
    cases result with
    | error reason =>
      change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
      have same := pure_ok call
      subst next
      rw [(return_trace tail).2] at confirmed
      simp [output, Command.perform, Command.finish, a] at confirmed
    | ok =>
      change (pure (output events .fence) : KernelM Term) j = .ok (next, r) at call
      have same := pure_ok call
      subst next
      cases tail with
      | done => simp [output, Command.perform, Command.finish, a] at confirmed
      | @resume state request token result next final j r rest call tail =>
        cases result with
        | ok => exact ⟨rest, rfl⟩
        | error reason =>
          change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
          have same := pure_ok call
          subst next
          rw [(return_trace tail).2] at confirmed
          simp [output, Command.perform, Command.finish, a] at confirmed

theorem input_start_trace_write_fence {start final : Term} {batch : List Term}
    {effects : List (Term × Result)} (started : InputStart start batch)
    (trace : Trace start effects final)
    (confirmed : final = Command.perform (.tuple [a "notify", b "input_accepted", list batch]) (b "input_notified") ∨
      final = Command.finish (.tuple [a "ok", a "committed"])) :
    ∃ before after, effects = before ++
      [(.tuple [a "write", list batch, list []], Result.ok), (a "durable_fence", Result.ok)] ++ after := by
  rcases started with rfl | ⟨operation, metadata, workspace, billing, rfl⟩
  · obtain ⟨after, same⟩ := write_trace_confirmation_prefix trace confirmed
    exact ⟨[], after, same⟩
  · cases trace with
    | done => simp [Command.perform, Command.finish, a] at confirmed
    | @resume state request token result next final j r effects call tail =>
      cases result with
      | ok =>
        change (pure (Command.writeInput (list batch)) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        obtain ⟨after, same⟩ := write_trace_confirmation_prefix tail confirmed
        exact ⟨[(_, Result.ok)], after, congrArg (List.cons _) same⟩
      | error reason =>
        change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
        have same := pure_ok call
        subst next
        rw [(return_trace tail).2] at confirmed
        simp [Command.perform, Command.finish, a] at confirmed

theorem write_trace_not_duplicate {events final : Term} {effects : List (Term × Result)}
    (trace : Trace (Command.writeInput events) effects final)
    (duplicate : final = Command.finish (.tuple [a "ok", a "duplicate"])) : False := by
  obtain ⟨last, value, _, _⟩ := trace_monitor trace (s := {}) rfl initial_safe
  rw [value] at duplicate
  cases phase : last.phase <;>
    simp [phase, output, Command.writeInput, Command.perform, Command.finish, a] at duplicate

theorem input_start_not_duplicate {start final : Term} {batch : List Term}
    {effects : List (Term × Result)} (started : InputStart start batch)
    (trace : Trace start effects final)
    (duplicate : final = Command.finish (.tuple [a "ok", a "duplicate"])) : False := by
  rcases started with rfl | ⟨operation, metadata, workspace, billing, rfl⟩
  · exact write_trace_not_duplicate trace duplicate
  · cases trace with
    | done => simp [Command.perform, Command.finish, a] at duplicate
    | @resume state request token result next final j r effects call tail =>
      cases result with
      | ok =>
        change (pure (Command.writeInput (list batch)) : KernelM Term) j = .ok (next, r) at call
        rw [pure_ok call] at tail
        exact write_trace_not_duplicate tail duplicate
      | error reason =>
        change (pure (Command.finish (.tuple [a "error", reason])) : KernelM Term) j = .ok (next, r) at call
        rw [pure_ok call] at tail
        rw [(return_trace tail).2] at duplicate
        simp [Command.finish, a] at duplicate

theorem input_command_duplicate_has_fence {s args result final : Term} {j r : List Term}
    {effects : List (Term × Result)}
    (input : Command.input s args j = .ok (result, r))
    (trace : Trace result effects final)
    (duplicate : final = Command.finish (.tuple [a "ok", a "duplicate"])) :
    result = Command.duplicateInput ∧ effects = [(a "durable_fence", Result.ok)] := by
  rcases input_start input with duplicateStart | saturated | invalid | ⟨batch, started, _, _⟩
  · exact ⟨duplicateStart, duplicate_confirmation_fenced (duplicateStart ▸ trace) duplicate⟩
  · rw [saturated] at trace
    rw [(return_trace trace).2] at duplicate
    simp [Command.finish, a] at duplicate
  · rw [invalid] at trace
    rw [(return_trace trace).2] at duplicate
    simp [Command.finish, a] at duplicate
  · exact (input_start_not_duplicate started trace duplicate).elim

end CommandExecution
end VerifiedKernel.Session.WorkConservation
