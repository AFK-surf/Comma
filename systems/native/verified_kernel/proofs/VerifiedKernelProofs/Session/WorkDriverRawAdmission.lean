import VerifiedKernelProofs.Session.WorkDriverInput

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- Admission follows public observation and effect requests with opaque resources. -/
inductive AdmissionTrace : Output → Output → Prop where
  | done (output : Output) : AdmissionTrace output output
  | observe {saved request observation : Term} {final : Output}
      (tail : AdmissionTrace (resident (some saved) (a "resume") observation) final) :
      AdmissionTrace (some saved, .tuple [a "observe", request]) final
  | effect {saved request response : Term} {final : Output}
      (tail : AdmissionTrace (resident (some saved) (a "effect_result") response) final) :
      AdmissionTrace (some saved, .tuple [a "effect", request]) final

theorem AdmissionTrace.first_effect {initial final : Output} (trace : AdmissionTrace initial final) :
    ObservationTrace initial final ∨ ∃ saved request response : Term,
      ObservationTrace initial (some saved, .tuple [a "effect", request]) ∧
      AdmissionTrace (resident (some saved) (a "effect_result") response) final := by
  induction trace with
  | done output => exact Or.inl (.done output)
  | observe tail ih =>
    rcases ih with observations | ⟨saved, request, response, head, rest⟩
    · exact Or.inl (.resume observations)
    · exact Or.inr ⟨saved, request, response, .resume head, rest⟩
  | @effect saved request response final tail =>
    exact Or.inr ⟨saved, request, response, .done _, tail⟩

theorem AdmissionTrace.fixed {initial final : Output} (trace : AdmissionTrace initial final)
    (terminal : ∀ request, initial.2 ≠ .tuple [a "observe", request] ∧
      initial.2 ≠ .tuple [a "effect", request]) : final = initial := by
  cases trace with
  | done => rfl
  | observe => exact ((terminal _).1 rfl).elim
  | effect => exact ((terminal _).2 rfl).elim

theorem input_workspace_admission_observations {context : Context}
    {args initial operation metadata workspace billing : Term} {journal rest original : List Term}
    {response : DurableConfirmation.Result} {final : Output}
    (input : Command.input context.candidate.working args journal = .ok (initial, rest))
    (started : InputStart initial original)
    (trace : AdmissionTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool true],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire) final) :
    ObservationTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool true],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire) final := by
  have fixed := input_write_unchanged (continuation := inputWriteContinuation original) input started
  cases response with
  | ok =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace ⊢
    change AdmissionTrace (issue context (Command.writeInput (list original))) final at trace
    change ObservationTrace (issue context (Command.writeInput (list original))) final
    rw [issue_input_write, fixed] at trace ⊢
    rw [trace.fixed (by simp [preparedWrite, a])]
    exact .done _
  | error reason =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace ⊢
    change AdmissionTrace (issue context (Command.finish (.tuple [a "error", reason]))) final at trace
    change ObservationTrace (issue context (Command.finish (.tuple [a "error", reason]))) final
    rw [trace.fixed (by simp [Command.finish, issue, a])]
    exact .done _

theorem effect_rejected (context : Context) (continuation request result : Term)
    (invalidResult : effectResultValid request result = false) :
    resident (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]))
      (a "effect_result") result = invalid := by
  have captured : resident
      (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]))
      (a "effect_result") result =
      if effectResultValid request result then
        query context (a "resume") (.tuple [continuation, result]) [] else invalid := by
    cases context <;> rfl
  rw [captured, invalidResult]
  rfl

theorem workspace_result_wire {operation metadata workspace billing result : Term}
    (valid : effectResultValid (.tuple [a "workspace", operation, metadata, workspace, billing]) result = true) :
    ∃ response : DurableConfirmation.Result, result = response.wire := by
  unfold effectResultValid at valid
  split at valid
  all_goals first
    | exact ⟨.ok, rfl⟩
    | exact ⟨.error _, rfl⟩
    | simp_all [a]
    | contradiction

/-- Malformed callbacks cannot reach admission's write boundary. -/
theorem workspace_admission_result {context : Context}
    {continuation operation metadata workspace billing result saved : Term} {events : List Term}
    (trace : AdmissionTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack, continuation,
        .tuple [a "workspace", operation, metadata, workspace, billing]])) (a "effect_result") result)
      (some saved, .tuple [a "validate_write", list events])) :
    ∃ response : DurableConfirmation.Result, result = response.wire := by
  cases valid : effectResultValid (.tuple [a "workspace", operation, metadata, workspace, billing]) result with
  | true => exact workspace_result_wire valid
  | false =>
    rw [effect_rejected _ _ _ _ valid] at trace
    have impossible := trace.fixed (by simp [invalid, RevisionFence.invalid, a])
    cases congrArg Prod.fst impossible

/-- The actual initial command admits at most one workspace effect before its write. -/
theorem input_admission_reflect {context : Context} {args checkpoint saved : Term}
    {observations events : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    InputAdmissionTrace context args checkpoint observations (some saved, .tuple [a "validate_write", list events]) := by
  rcases trace.first_effect with direct | ⟨effect, request, response, head, tail⟩
  · exact .direct direct
  · obtain ⟨journal, result, rest, original, operation, metadata, workspace, billing,
      call, started, requestEq, savedEq⟩ := input_initial_workspace head
    rw [savedEq, requestEq] at tail
    obtain ⟨response, rfl⟩ := workspace_admission_result tail
    apply InputAdmissionTrace.workspace (response := response) head
    rw [savedEq, requestEq]
    exact input_workspace_admission_observations call started tail

end VerifiedKernel.Session.CommandDriver
