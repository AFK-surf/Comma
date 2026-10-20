import VerifiedKernel.Session.Loop
import VerifiedKernelProofs.Proof.NativeProducerTactic

/-! # Query oracle answers

`Loop.queryAsk` looks an operation up in `queryTable` by name, and the kernel checks each `rfl`
proof by evaluating that lookup. This module imports only the runtime, so it builds while the
Session proofs build. The loop proofs restate these equations without another lookup. -/

namespace VerifiedKernel.Session.LoopProof.QueryAnswers
open Data
set_option Elab.async false

theorem runaway_retirement (s args : Term) :
    Loop.queryAsk s "runaway_retirement" args = Settlement.retireRunaway s := by rfl
theorem guard_local (s args : Term) :
    Loop.queryAsk s "guard_failure_local_settlement" args = Settlement.guardLocalSettlement s := by rfl
theorem guard_prepare (s args : Term) :
    Loop.queryAsk s "guard_failure_prepare" args =
      (native_decl% "VerifiedKernel.Session.Settlement.guardPrepare") s args := by rfl
theorem guard_cleanup (s args : Term) :
    Loop.queryAsk s "guard_failure_cleanup_events" args =
      (native_decl% "VerifiedKernel.Session.Settlement.guardCleanupEvents") s args := by rfl
theorem finish_output (s args : Term) :
    Loop.queryAsk s "finish_output" args =
      (Presentation.table.lookup "finish_output").getD (fun _ _ => fail "function_clause") s args := by rfl
theorem settle (s args : Term) :
    Loop.queryAsk s "settle_tool_batch" args = Settlement.batch s args := by rfl
theorem wait_timeout (s args : Term) :
    Loop.queryAsk s "wait_timeout_event" args = Command.waitTimeout s args := by rfl
theorem yield_events (s args : Term) :
    Loop.queryAsk s "provider_wait_yield_events" args = StateQuery.waitYieldEvents s args := by rfl
theorem onboarding (s args : Term) :
    Loop.queryAsk s "onboarding_settlement" args = (do
      let .tuple [results, events, router] := args | fail "function_clause"
      Settlement.onboarding s (← asList results) (← asList events) router.truthy) := by rfl
theorem activation_next (s args : Term) :
    Loop.queryAsk s "activation_next" args =
      (native_decl% "VerifiedKernel.Session.Command.activationNext") s args := by rfl
theorem archive_match_prefix :
    lookupOp queryTable (a "archive_match_prefix") = some ArchiveMatch.check := rfl
theorem llm_failure_ack (s : Term) :
    Loop.queryAsk s "llm_failure_ack?" nil = (do return Term.bool (← RoundQuery.llmFailureAck s)) := by rfl

end VerifiedKernel.Session.LoopProof.QueryAnswers
