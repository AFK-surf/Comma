import VerifiedKernelProofs.Session.WorkLedgerOrigins
import VerifiedKernelProofs.Session.WorkInputAdmissionActual
import VerifiedKernelProofs.Session.WorkDriverRawAdmission

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem duplicateDelivery_present {state source value : Term} {journal rest : List Term}
    (call : RoundQuery.duplicateDelivery state source journal = .ok (value, rest))
    (positive : value.truthy = true) :
    IdentityPresent (state.get (a "input_dedupe")) source := by
  unfold RoundQuery.duplicateDelivery at call
  split at call
  · rw [pure_ok call] at positive
    contradiction
  next nonnil =>
    obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
    have ledgerEq := field_value ledgerRead
    subst ledger
    obtain ⟨present, _, presentRead, call⟩ := bind_ok call
    rw [pure_ok call] at positive
    cases present with
    | true => exact (setMember_value presentRead).symm
    | false => contradiction

def InputSourceAlias (source key : Term) : Prop :=
  key = source ∨ ∃ journal rest, stringify source journal = .ok (key, rest)

theorem InputSourceAlias.binary {source : ByteArray} {key : Term}
    (alias : InputSourceAlias (.binary source) key) : key = .binary source := by
  rcases alias with same | ⟨journal, rest, normalized⟩
  · exact same
  · unfold stringify at normalized
    obtain ⟨_, _, _, normalized⟩ := bind_ok normalized
    exact stringifyFuel_binary_value normalized

theorem deliveryAdmission_duplicate_alias {state payload limit source : Term} {journal rest : List Term}
    (call : RoundQuery.deliveryAdmission state (.tuple [source, payload, limit]) journal = .ok (a "duplicate", rest)) :
    ∃ key, InputSourceAlias source key ∧ IdentityPresent (state.get (a "input_dedupe")) key := by
  unfold RoundQuery.deliveryAdmission at call
  obtain ⟨duplicate, _, duplicateRead, call⟩ := bind_ok call
  cases raw : duplicate.truthy with
  | true => exact ⟨source, Or.inl rfl, duplicateDelivery_present duplicateRead raw⟩
  | false =>
    simp only [raw, Bool.false_eq_true, ↓reduceIte] at call
    split at call
    · obtain ⟨normalized, first, normalizedRead, call⟩ := bind_ok call
      obtain ⟨hit, _, hitRead, call⟩ := bind_ok call
      cases matched : hit.truthy with
      | true => exact ⟨normalized, Or.inr ⟨_, _, normalizedRead⟩, duplicateDelivery_present hitRead matched⟩
      | false =>
        simp only [matched, Bool.and_false, Bool.false_eq_true, ↓reduceIte] at call
        repeat' first
          | (have impossible := pure_ok call; simp [a] at impossible)
          | (obtain ⟨_, _, _, call⟩ := bind_ok call)
          | split at call
          | dsimp only at call
    · repeat' first
        | (have impossible := pure_ok call; simp [a] at impossible)
        | (obtain ⟨_, _, _, call⟩ := bind_ok call)
        | split at call
        | dsimp only at call

theorem deliveryAdmission_duplicate_present {state payload limit : Term} {source : ByteArray}
    {journal rest : List Term}
    (call : RoundQuery.deliveryAdmission state (.tuple [.binary source, payload, limit]) journal = .ok (a "duplicate", rest)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) := by
  obtain ⟨key, alias, present⟩ := deliveryAdmission_duplicate_alias call
  rwa [alias.binary] at present

theorem commit_input_not_duplicate {state entry : Term} {trailing journal rest : List Term} {notify : Bool}
    (call : Command.commitInput state entry trailing notify journal = .ok (Command.duplicateInput, rest)) : False := by
  unfold Command.commitInput at call
  repeat' first
    | (have impossible := pure_ok call
       simp [Command.duplicateInput, Command.perform, Command.finish, Command.writeInput, a] at impossible)
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem input_duplicate_alias {state entry born source : Term} {journal rest : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (call : Command.input state (.tuple [entry, born]) journal = .ok (Command.duplicateInput, rest)) :
    ∃ key, InputSourceAlias source key ∧ IdentityPresent (state.get (a "input_dedupe")) key := by
  unfold Command.input at call
  obtain ⟨limit, _, _, call⟩ := bind_ok call
  obtain ⟨admission, _, admitted, call⟩ := bind_ok call
  change RoundQuery.deliveryAdmission state (.tuple [RoundQuery.atomFirst entry "source_message_id",
    RoundQuery.atomFirst entry "payload", limit]) _ = .ok (admission, _) at admitted
  rw [sourceValue] at admitted
  rcases deliveryAdmission_outcomes admitted with duplicate | saturated | accepted
  · rw [duplicate] at admitted
    exact deliveryAdmission_duplicate_alias admitted
  · rw [saturated] at call
    have impossible := pure_ok call
    simp [Command.duplicateInput, Command.perform, Command.finish, a] at impossible
  · rw [accepted] at call
    repeat' first
      | exact (commit_input_not_duplicate call).elim
      | exact (fail_ok call).elim
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | split at call
      | dsimp only at call

theorem input_duplicate_present {state entry born : Term} {source : ByteArray} {journal rest : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (call : Command.input state (.tuple [entry, born]) journal = .ok (Command.duplicateInput, rest)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) := by
  obtain ⟨key, alias, present⟩ := input_duplicate_alias sourceValue call
  rwa [alias.binary] at present

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- The initial input query can request a fence only for its actual duplicate result. -/
theorem input_initial_duplicate_alias {context : Context} {entry born checkpoint saved source : Term}
    {observations : List Term} (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"])) :
    saved = .tuple [a "session_command_driver_fence", context.pack, b "input_duplicate_fenced"] ∧
    ∃ key, InputSourceAlias source key ∧
      IdentityPresent (context.candidate.working.get (a "input_dedupe")) key := by
  obtain ⟨journal, result, rest, call, _, issued⟩ := input_trace_actual trace (by simp [QueryTerminal, a])
  rcases input_start call with duplicate | saturated | invalidInput | ⟨batch, started, _, _⟩
  · rw [duplicate] at call issued
    exact ⟨Option.some.inj (congrArg Prod.fst issued), input_duplicate_alias sourceValue call⟩
  · rw [saturated] at issued
    simp [Command.finish, issue, a] at issued
  · rw [invalidInput] at issued
    simp [Command.finish, issue, a] at issued
  · have fixed := input_write_unchanged (continuation := inputWriteContinuation batch) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_input_write, fixed] at issued
      simp [preparedWrite, a] at issued
    · rw [workspaceStart] at issued
      simp [Command.perform, issue, a] at issued

theorem input_raw_duplicate_alias {context : Context} {entry born checkpoint saved source : Term}
    {observations : List Term} (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"])) :
    saved = .tuple [a "session_command_driver_fence", context.pack, b "input_duplicate_fenced"] ∧
    ∃ key, InputSourceAlias source key ∧
      IdentityPresent (context.candidate.working.get (a "input_dedupe")) key := by
  rcases trace.first_effect with direct | ⟨effect, request, response, head, tail⟩
  · exact input_initial_duplicate_alias sourceValue direct
  · obtain ⟨journal, result, rest, original, operation, metadata, workspace, billing,
      call, started, requestEq, savedEq⟩ := input_initial_workspace head
    rw [savedEq, requestEq] at tail
    cases valid : effectResultValid (.tuple [a "workspace", operation, metadata, workspace, billing]) response with
    | false =>
      rw [effect_rejected _ _ _ _ valid] at tail
      have impossible := tail.fixed (by simp [invalid, RevisionFence.invalid, a])
      cases congrArg Prod.fst impossible
    | true =>
      obtain ⟨response, rfl⟩ := workspace_result_wire valid
      cases response with
      | ok =>
        rw [effect_captured _ _ _ _ (by rfl)] at tail
        change AdmissionTrace (issue context (Command.writeInput (list original))) _ at tail
        rw [issue_input_write, input_write_unchanged call started] at tail
        have impossible := tail.fixed (by simp [preparedWrite, a])
        simp [preparedWrite, a] at impossible
      | error reason =>
        rw [effect_captured _ _ _ _ (by rfl)] at tail
        change AdmissionTrace (issue context (Command.finish (.tuple [a "error", reason]))) _ at tail
        have impossible := tail.fixed (by simp [Command.finish, issue, a])
        simp [Command.finish, issue, a] at impossible

theorem input_initial_duplicate {context : Context} {entry born checkpoint saved : Term} {source : ByteArray}
    {observations : List Term} (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"])) :
    saved = .tuple [a "session_command_driver_fence", context.pack, b "input_duplicate_fenced"] ∧
      IdentityPresent (context.candidate.working.get (a "input_dedupe")) (.binary source) := by
  obtain ⟨same, key, alias, present⟩ := input_initial_duplicate_alias sourceValue trace
  exact ⟨same, alias.binary ▸ present⟩

theorem input_raw_duplicate {context : Context} {entry born checkpoint saved : Term} {source : ByteArray}
    {observations : List Term} (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", .tuple [entry, born], checkpoint], list observations]))
      (some saved, .tuple [a "fence"])) :
    saved = .tuple [a "session_command_driver_fence", context.pack, b "input_duplicate_fenced"] ∧
      IdentityPresent (context.candidate.working.get (a "input_dedupe")) (.binary source) := by
  obtain ⟨same, key, alias, present⟩ := input_raw_duplicate_alias sourceValue trace
  exact ⟨same, alias.binary ▸ present⟩

/-- A clean confirmation can reuse only the exact committed constructor, never a fresh or pending revision. -/
theorem clean_fence_capture {context : Context} {continuation args confirmed : Term}
    (call : resident (some (.tuple [a "session_command_driver_fence", context.pack, continuation]))
      (a "fence_clean") args = (some confirmed, .tuple [a "committed"])) :
    ∃ state etag, context = .committed state etag ∧
      confirmed = .tuple [a "session_command_driver_confirmed", context.pack, continuation] := by
  cases context with
  | fresh state => cases congrArg Prod.fst call
  | pending cursor => cases congrArg Prod.fst call
  | committed state etag =>
    exact ⟨state, etag, rfl, (Option.some.inj (congrArg Prod.fst call)).symm⟩

theorem duplicate_return_captured (state etag : Term) :
    resident (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack,
      b "input_duplicate_fenced"])) (a "next") nil =
    (some (Revision.Cursor.committed state etag).pack,
      .tuple [a "return", .tuple [a "ok", a "duplicate"], nil]) := rfl

end VerifiedKernel.Session.CommandDriver
