import VerifiedKernelProofs.Order
import VerifiedKernelProofs.IFC.SystemRefinement

/-! Constructive witnesses and unsafe variants. These use kernel-checked proofs,
not native_decide. Unsafe variants are confined to this specification module. -/
namespace VerifiedKernel.IFC.SystemExamples
open VerifiedKernel.IFC.System

@[reducible] local instance defaultDomain : Domain :=
  ⟨Nat, Nat, Nat, Nat, inferInstance, inferInstance, inferInstance, inferInstance⟩

local instance (n : Nat) : OfNat (@Principal defaultDomain) n := ⟨n⟩
local instance (n : Nat) : OfNat (@Audience defaultDomain) n := ⟨n⟩
local instance (n : Nat) : OfNat (@Ref defaultDomain) n := ⟨n⟩
local instance (n : Nat) : OfNat (@ReceiptId defaultDomain) n := ⟨n⟩

def aliceOnly : Label := [.audience 0]
def everyone : Label := [.unrestricted]
def world : World := ⟨fun _ p => p = 0⟩
def grant : Receipt := ⟨0, aliceOnly, everyone, some 100⟩
def request : Consent.Request := ⟨grant, 10⟩

theorem private_does_not_flow_public : ¬ Flows world aliceOnly everyone := by
  intro h
  have leaked := h 1 (by simp [Reads, everyone, AtomReads])
  have impossible := leaked (.audience 0) (by simp [aliceOnly])
  exact Nat.noConfusion impossible

theorem approval_can_be_consumed :
    (Consent.run request {} [.approve 0 0, .mint, .consume 7]).owner = some 7 := by
  rfl

theorem denial_replay_cannot_mint :
    (Consent.run request {} [.deny 0 0, .approve 0 0, .mint]).minted = 0 := by
  rfl

theorem late_approval_cannot_mint :
    (Consent.run request {} [.approve 0 10, .mint]).minted = 0 := by
  rfl

theorem other_actor_cannot_mint :
    (Consent.run request {} [.approve 1 0, .mint]).minted = 0 := by
  rfl

theorem competing_consumer_loses :
    (Consent.run request {} [.approve 0 0, .mint, .consume 7, .consume 8]).owner = some 7 := by
  rfl

theorem crash_between_writes_can_lose_grant :
    let s := Consent.run request {} [.approve 0 0, .crash, .mint]
    s.status = .approved ∧ s.minted = 0 := by
  exact ⟨rfl, rfl⟩

/-- Mutation: consumption fails to remove the receipt. Two claims break Safe. -/
def unsafeConsume (s : Consent.State) (attempt : AttemptId) : Consent.State :=
  if s.available then { s with owner := some attempt, claims := s.claims + 1 } else s

theorem reusable_receipt_counterexample :
    let issued := Consent.run request {} [.approve 0 0, .mint]
    ¬ Consent.Safe (unsafeConsume (unsafeConsume issued 7) 8) := by
  simp [Consent.Safe, Consent.run, Consent.step, Consent.bit, unsafeConsume, request, grant]

/-- Mutation: a replay receives a new mint permit after the first claim. -/
theorem replay_settlement_counterexample :
    let spent := Consent.run request {} [.approve 0 0, .mint, .consume 7]
    let replayed := { spent with mintPermit := true }
    ¬ Consent.Safe (Consent.step request replayed .mint) := by
  simp [Consent.Safe, Consent.run, Consent.step, Consent.bit, request, grant]

def source : Item := ⟨0, aliceOnly, .command, some 0⟩
def activation : Activation := ⟨0, everyone, [0]⟩
def effect : Effect := ⟨0, .context, everyone⟩
def policy : Policy := ⟨fun _ => False, False, False, True⟩
def gates : Gates := ⟨.any, false, .deny, .receipt, True⟩

/-- Mutation: an omitted declaration is resolved as an empty source list. -/
theorem omitted_sources_counterexample : ¬ Resolves [source] .context [] := by
  simp [Resolves]

theorem data_cannot_command :
    ¬ RequestAuthorized [{ source with integrity := .data }] activation effect := by
  simp [RequestAuthorized]

/-- Residual limit: explicit empty sources can pass authorization even when an
LLM actually used private content. Source completeness is an external premise. -/
theorem dishonest_declaration_counterexample :
    Authorized world policy [source] activation { effect with sources := .explicit [] }
      (fun _ => none) 0 gates [] ∧ ¬ SourcesComplete [aliceOnly] [] := by
  constructor
  · refine ⟨?_, ?_, explicit_empty_resolves, ?_⟩
    · exact ⟨source, by simp, rfl, rfl, rfl, by simp [activation, source]⟩
    · simp [gates, Gates.Hold]
    · simp
  · simp [SourcesComplete]

theorem unsound_flow_observation_counterexample :
    ¬ (Tri.yes = .yes → Flows world aliceOnly everyone) := by
  intro h
  exact private_does_not_flow_public (h rfl)

/-- A resolver still reports an Alice-only destination, but its real audience
includes Bob. This covers stale membership and wrong Task-audience facts. -/
def expandedAudience : World := ⟨fun audience p => audience = 1 ∨ p = 0⟩

theorem reader_expansion_counterexample :
    Flows world aliceOnly [.audience 1] ∧
      ¬ Flows expandedAudience aliceOnly [.audience 1] := by
  constructor
  · simp [Flows, Reads, AtomReads, world, aliceOnly]
  · intro flow
    have leaked := flow 1 (by simp [Reads, AtomReads, expandedAudience])
    have impossible := leaked (.audience 0) (by simp [aliceOnly])
    simp [AtomReads, expandedAudience] at impossible

theorem revoked_scope_blocks_authorization
    {w : World} {policy : Policy} {activation : Activation} {effect : Effect} {gates : Gates}
    (revoked : ¬ gates.commandScope) :
    ¬ Authorized w policy ctx activation effect receipts now gates evidence := by
  intro authorized
  exact revoked authorized.2.1.2.2.2

def dispatch : Dispatch :=
  { attempt := 7, world, policy, context := [source], activation, effect,
    receipts := fun _ => some grant, now := 0, gates,
    evidence := [⟨source, .receipt 0⟩] }

theorem receipt_dispatch_authorized : dispatch.Authorized := by
  refine ⟨?_, ?_, by simp [dispatch, effect, Resolves], ?_⟩
  · exact ⟨source, by simp [dispatch], rfl, rfl, rfl, by simp [dispatch, activation, source]⟩
  · simp [dispatch, gates, Gates.Hold]
  · intro entry he
    have heq : entry = ⟨source, .receipt 0⟩ := List.mem_singleton.mp he
    subst entry
    apply SourceAuthorized.receipt
    · simp [Unsealed, dispatch, policy]
    · simp [Reads, dispatch, activation, source, aliceOnly, AtomReads, world]
    · trivial
    · rfl
    · simp [Covers, dispatch, grant, activation, source, effect, LabelEq]

/-- A full nonempty system trace, including the two durable writes and claim. -/
theorem receipt_dispatch_reachable :
    ∃ s, Reachable (fun _ => request) s ∧ dispatch ∈ s.dispatched := by
  let s0 : State := {}
  let s1 : State := { ledger := fun key =>
    if key = 0 then Consent.step request (s0.ledger 0) (.approve 0 0) else s0.ledger key }
  let s2 : State := { ledger := fun key =>
    if key = 0 then Consent.step request (s1.ledger 0) .mint else s1.ledger key }
  let s3 : State := { ledger := fun key =>
    if key = 0 then Consent.step request (s2.ledger 0) (.consume 7) else s2.ledger key }
  have h1 : Reachable (fun _ => request) s1 :=
    .step .initial (.receipt s0 0 (.approve 0 0))
  have h2 : Reachable (fun _ => request) s2 := .step h1 (.receipt s1 0 .mint)
  have h3 : Reachable (fun _ => request) s3 := .step h2 (.receipt s2 0 (.consume 7))
  refine ⟨{ s3 with dispatched := [dispatch] }, ?_, by simp⟩
  apply Reachable.step h3
  apply Step.dispatch s3 dispatch receipt_dispatch_authorized
  · intro id _; rfl
  · intro id hu
    obtain ⟨entry, he, hc⟩ := hu
    have heq : entry = ⟨source, .receipt 0⟩ := List.mem_singleton.mp he
    subst entry
    have hid : id = 0 := (Clause.receipt.inj hc).symm
    subst id
    rfl
  · simp [s3]

end VerifiedKernel.IFC.SystemExamples
