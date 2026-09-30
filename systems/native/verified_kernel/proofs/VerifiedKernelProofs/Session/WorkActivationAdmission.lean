import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkActivationCallbacks
import VerifiedKernelProofs.Session.WorkDriverRawAdmission

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def ActivationQuery (operation args : Term) : Prop :=
  (operation = a "start" ∧ ∃ hwm prompt active checkpoint,
    args = .tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint]) ∨
  (operation = a "resume" ∧ ∃ continuation response,
    args = .tuple [continuation, response] ∧ ActivationCallback continuation)

theorem activation_query_result {context : Context} {operation args result : Term} {journal rest : List Term}
    (allowed : ActivationQuery operation args)
    (call : queryCall context operation args journal = .ok (result, rest)) :
    ActivationCommandEvents result ∧ ActivationCommandCallbacks result := by
  rcases allowed with ⟨rfl, hwm, prompt, active, checkpoint, rfl⟩ | ⟨rfl, continuation, response, rfl, callback⟩
  · exact ⟨activation_command_events call, activation_command_callbacks call⟩
  · exact activation_callback_safe callback call

theorem activation_timestamp_event {event : Term} (now : Int)
    (valid : BinaryKeys event ∧ ActivationEvent event) :
    BinaryKeys (Command.timestampLifecycle event now) ∧ ActivationEvent (Command.timestampLifecycle event now) := by
  refine ⟨timestampLifecycle_binary_keys now valid.1, ?_⟩
  have kind : (Command.timestampLifecycle event now).get (b "type") = event.get (b "type") := by
    unfold Command.timestampLifecycle
    split
    · exact get_put_binary_other _ _ (by decide)
    · rfl
  simpa only [ActivationEvent, kind] using valid.2

theorem activation_timestamp_batch {events : List Term} (now : Int) (batch : ActivationBatch events) :
    ActivationBatch (events.map (fun event => Command.timestampLifecycle event now)) := by
  intro event member
  obtain ⟨original, originalMember, rfl⟩ := List.mem_map.mp member
  exact activation_timestamp_event now (batch original originalMember)

/-- Before its first write, each resource retains the original revision and a kernel-derived continuation. -/
inductive ActivationAdmissionOutput (context : Context) : Output → Prop where
  | querying (operation args request : Term) (observations : List Term)
      (allowed : ActivationQuery operation args) :
      ActivationAdmissionOutput context
        (some (queryCursor context operation args observations), .tuple [a "observe", request])
  | timestamp (continuation : Term) (events : List Term) (hwm : Term)
      (batch : ActivationBatch events) (fenced : ActivationPostWrite continuation) :
      ActivationAdmissionOutput context
        (some (.tuple [a "session_command_driver_write_time", context.pack, continuation, list events, hwm]),
          .tuple [a "observe", a "time"])
  | write (continuation : Term) (events : List Term) (hwm : Term)
      (batch : ActivationBatch events) (fenced : ActivationPostWrite continuation) :
      ActivationAdmissionOutput context (preparedWrite context continuation events hwm)
  | effect (request continuation : Term) (callback : ActivationCallback continuation) :
      ActivationAdmissionOutput context
        (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]),
          .tuple [a "effect", request])
  | returned (result checkpoint : Term) :
      ActivationAdmissionOutput context (some context.pack, .tuple [a "return", result, checkpoint])
  | fence (continuation : Term) :
      ActivationAdmissionOutput context
        (some (.tuple [a "session_command_driver_fence", context.pack, continuation]), .tuple [a "fence"])
  | failed (response : Term) : ActivationAdmissionOutput context (none, response)

theorem activation_issue_write_valid (context : Context) (continuation : Term) (events : List Term) (hwm : Term)
    (batch : ActivationBatch events) (fenced : ActivationPostWrite continuation) :
    ActivationAdmissionOutput context (issueWrite context continuation events hwm) := by
  unfold issueWrite
  split
  · exact .timestamp _ _ _ batch fenced
  · exact .write _ _ _ batch fenced

theorem activation_issue_valid (context : Context) (result : Term)
    (events : ActivationCommandEvents result) (callbacks : ActivationCommandCallbacks result) :
    ActivationAdmissionOutput context (issue context result) := by
  unfold issue
  split
  · exact .returned _ _
  · exact activation_issue_write_valid _ _ _ _ events callbacks
  · exact activation_issue_write_valid _ _ _ _ events callbacks
  · exact activation_issue_write_valid _ _ _ _ events callbacks
  · exact .fence _
  · exact .effect _ _ callbacks
  · exact .effect _ _ callbacks
  · exact .effect _ _ callbacks
  · exact .effect _ _ callbacks
  · exact .effect _ _ callbacks
  · exact .failed _

theorem activation_query_valid (context : Context) (operation args : Term) (observations : List Term)
    (allowed : ActivationQuery operation args) : ActivationAdmissionOutput context (query context operation args observations) := by
  rw [query_eq]
  split
  · rename_i result rest call
    split
    · have safe := activation_query_result allowed call
      exact activation_issue_valid _ _ safe.1 safe.2
    · exact .failed _
  · exact .querying _ _ _ _ allowed
  · exact .failed _

set_option smartUnfolding false in
theorem activation_timestamp_response (context : Context) (continuation observation : Term)
    (events : List Term) (hwm : Term) :
    resident (some (.tuple [a "session_command_driver_write_time", context.pack, continuation, list events, hwm]))
      (a "resume") observation =
      match observation with
      | .tuple [.atom "ok", .integer milliseconds] =>
        preparedWrite context continuation (events.map (fun event => Command.timestampLifecycle event (milliseconds / 1000))) hwm
      | _ => invalid := by
  cases context <;> rfl

theorem activation_observe_valid {context : Context} {saved request observation : Term}
    (valid : ActivationAdmissionOutput context (some saved, .tuple [a "observe", request])) :
    ActivationAdmissionOutput context (resident (some saved) (a "resume") observation) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | querying operation args _ observations allowed =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured, query_resume_captured]
    exact activation_query_valid _ _ _ _ allowed
  | timestamp continuation events hwm batch fenced =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured, activation_timestamp_response]
    split
    · exact .write _ _ _ (activation_timestamp_batch _ batch) fenced
    · exact .failed _
  | write => simp [preparedWrite, a] at same
  | effect => simp [a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem activation_effect_valid {context : Context} {saved request response : Term}
    (valid : ActivationAdmissionOutput context (some saved, .tuple [a "effect", request])) :
    ActivationAdmissionOutput context (resident (some saved) (a "effect_result") response) := by
  generalize same : (some saved, Term.tuple [a "effect", request]) = output at valid
  cases valid with
  | effect issued continuation callback =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured]
    cases allowed : effectResultValid issued response with
    | true =>
      rw [effect_captured _ _ _ _ allowed]
      exact activation_query_valid _ _ _ _ (Or.inr ⟨rfl, continuation, response, rfl, callback⟩)
    | false =>
      rw [effect_rejected _ _ _ _ allowed]
      exact .failed _
  | querying => simp [a] at same
  | timestamp => simp [a] at same
  | write => simp [preparedWrite, a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem activation_admission_preserved {context : Context} {initial final : Output}
    (trace : AdmissionTrace initial final) (valid : ActivationAdmissionOutput context initial) :
    ActivationAdmissionOutput context final := by
  induction trace with
  | done => exact valid
  | observe tail ih => exact ih (activation_observe_valid valid)
  | effect tail ih => exact ih (activation_effect_valid valid)

theorem activation_write_shape {context : Context} {saved : Term} {events : List Term}
    (valid : ActivationAdmissionOutput context (some saved, .tuple [a "validate_write", list events])) :
    ∃ continuation hwm,
      saved = .tuple [a "session_command_driver_write", context.pack, continuation, list events, hwm] ∧
      ActivationBatch events ∧ ActivationPostWrite continuation := by
  generalize same : (some saved, Term.tuple [a "validate_write", list events]) = output at valid
  cases valid with
  | write continuation written hwm batch fenced =>
    have eventEq : events = written := by
      simpa only [preparedWrite, Term.tuple.injEq, List.cons.injEq, and_true, true_and, list, Term.list.injEq]
        using congrArg Prod.snd same
    subst written
    exact ⟨continuation, hwm, Option.some.inj (congrArg Prod.fst same), batch, fenced⟩
  | querying => simp [a] at same
  | timestamp => simp [a] at same
  | effect => simp [a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

/-- The public response loop derives the captured activation batch and mandatory fence from the initial command. -/
theorem activation_admission_captured {context : Context} {hwm prompt active checkpoint saved : Term}
    {observations events : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    ∃ continuation capturedHwm,
      saved = .tuple [a "session_command_driver_write", context.pack, continuation, list events, capturedHwm] ∧
      ActivationBatch events ∧ ActivationPostWrite continuation := by
  apply activation_write_shape
  apply activation_admission_preserved trace
  rw [start_captured]
  exact activation_query_valid _ _ _ _ (Or.inl ⟨rfl, hwm, prompt, active, checkpoint, rfl⟩)

end VerifiedKernel.Session.CommandDriver
