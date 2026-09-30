import VerifiedKernelProofs.IFC.SemanticRefinement

namespace VerifiedKernel.IFC.TransferSystem
open Data Identity WireSemantics SemanticRefinement
local instance : System.Domain := domain

/-- A successful atomic deletion is one consume transition. Other consent
operations can interleave between any two observations. The SQL adapter is the
owner of this primitive's linearization point. -/
inductive StoreTrace (requests : System.ReceiptId → System.Consent.Request) (attempt : Nat) :
    System.State → List (ByteArray × Term) → System.State → Prop where
  | nil : StoreTrace requests attempt state [] state
  | interleave (step : System.Step requests state next)
      (tail : StoreTrace requests attempt next observations final) :
      StoreTrace requests attempt state observations final
  | claim {id : ByteArray}
      (available : (state.ledger (key (.binary id))).available = true)
      (tail : StoreTrace requests attempt
        { state with ledger := fun ref => if ref = key (.binary id) then
            System.Consent.step (requests (key (.binary id))) (state.ledger (key (.binary id))) (.consume attempt)
          else state.ledger ref }
        observations final) :
      StoreTrace requests attempt state ((id, .tuple [a "ok", a "true"]) :: observations) final

theorem trace_reachable (reachable : System.Reachable requests state)
    (trace : StoreTrace requests attempt state observations final) : System.Reachable requests final := by
  induction trace with
  | nil => exact reachable
  | interleave step _ ih => exact ih (.step reachable step)
  | @claim state observations final id available tail ih =>
    apply ih
    exact .step reachable (.receipt state (key (.binary id)) (.consume attempt))

theorem step_owner_stable {id : System.ReceiptId} (safe : System.Safe requests state)
    (step : System.Step requests state next) (owner : (state.ledger id).owner = some attempt) :
    (next.ledger id).owner = some attempt := by
  cases step with
  | receipt key event =>
    by_cases same : id = key
    · subst id
      simpa using System.Consent.owner_stable (r := requests key) (event := event) (safe.1 key) owner
    · simpa [same] using owner
  | dispatch => exact owner

theorem trace_owner_stable {id : System.ReceiptId} (reachable : System.Reachable requests state)
    (trace : StoreTrace requests attempt state observations final)
    (owner : (state.ledger id).owner = some ownerAttempt) : (final.ledger id).owner = some ownerAttempt := by
  induction trace with
  | nil => exact owner
  | interleave step _ ih =>
    exact ih (.step reachable step) (step_owner_stable (System.reachable_safe reachable) step owner)
  | @claim state observations final bytes available tail ih =>
    have step := System.Step.receipt (requests := requests) state (key (.binary bytes)) (.consume attempt)
    exact ih (.step reachable step) (step_owner_stable (System.reachable_safe reachable) step owner)

theorem successful_claim_owned (reachable : System.Reachable requests state)
    (trace : StoreTrace requests attempt state observations final)
    (success : (bytes, .tuple [a "ok", a "true"]) ∈ observations) :
    (final.ledger (key (.binary bytes))).owner = some attempt := by
  induction trace with
  | nil => simp at success
  | interleave step _ ih => exact ih (.step reachable step) success
  | @claim state observations final id available tail ih =>
    have step := System.Step.receipt (requests := requests) state (key (.binary id)) (.consume attempt)
    have nextReachable := System.Reachable.step reachable step
    rcases List.mem_cons.mp success with same | later
    · have equal : bytes = id := congrArg Prod.fst same
      subst bytes
      apply trace_owner_stable nextReachable tail
      simp only [↓reduceIte, System.Consent.step, available]
    · exact ih nextReachable later

/-- The executable receipt continuation, not an assumed all-receipts-owned
predicate, supplies the claims required by the system dispatch rule. -/
theorem transfer_claims_owned {sources entries : List Term} {id : System.ReceiptId}
    (reachable : System.Reachable requests state)
    (complete : Transfer.Completes (Transfer.start evidence) observations)
    (trace : StoreTrace requests attempt state observations final)
    (h : DecisionContract.EvidenceSources rawEffect rawActivation p facts sources entries)
    (wireEntries : values (f evidence "sources") = entries)
    (valid : ∀ raw ∈ setValues (f facts "receipts"), (f raw "id").isBinary = true)
    (present : entry ∈ admissions sources entries) (used : entry.clause = .receipt id) :
    (final.ledger id).owner = some attempt := by
  obtain ⟨bytes, raw, member, isReceipt, same⟩ := evidence_receipt h valid present used
  have inIds := Transfer.ids_cover (evidence := evidence) (by simpa [wireEntries] using member) isReceipt
  have success := Transfer.complete_claims complete bytes inIds
  simpa [same] using successful_claim_owned reachable trace success

theorem checked_receipt_ids_valid
    (allowed : decideChecked rawEffect rawActivation rawItems facts = .ok evidence) :
    ∀ raw ∈ setValues (f facts "receipts"), (f raw "id").isBinary = true := by
  have valid := (FullRefinement.decideChecked_sound allowed).1
  rcases valid with ⟨_, _, _, _, _, _, _, _, _, _, _, factsH⟩
  simp only [factsValid, Bool.and_eq_true] at factsH
  intro raw member
  have receiptH := List.all_eq_true.mp factsH.1.1.1.2 raw member
  simp only [receiptValid, Bool.and_eq_true] at receiptH
  exact receiptH.1.1.1.1.2

theorem checked_transfer_dispatch {commandScope : Prop}
    (allowed : decideChecked rawEffect rawActivation rawItems facts = .ok evidence)
    (sound : ReaderRefinement.FactsSound mapping w facts)
    (snapshot : ReceiptSnapshot facts receipts) (scope : commandScope)
    (reachable : System.Reachable requests state)
    (complete : Transfer.Completes (Transfer.start evidence) observations)
    (trace : StoreTrace requests attempt state observations final)
    (grants : ∀ id r, receipts id = some r → r = (requests id).grant)
    (fresh : ∀ old ∈ final.dispatched, old.attempt ≠ attempt) :
    ∃ (request : Term) (clock : Int) (sources entries : List Term) (revisions : Term),
      evidence = .map [
        (a "__struct__", a "Elixir.SalixIFC.Evidence"),
        (a "request", f rawEffect "request"), (a "requester", authority (f request "principal")),
        (a "destination", f rawEffect "destination"), (a "sources", list entries),
        (a "membership_revisions", revisions)] ∧
      System.Reachable requests
        { final with dispatched := {
            attempt, world := w, policy := policy (f facts "policy"),
            context := (values rawItems).map item, activation := activation rawActivation,
            effect := effect rawEffect, receipts, now := clock.toNat,
            gates := gates rawEffect (f request "principal") facts commandScope,
            evidence := admissions sources entries } :: final.dispatched } := by
  obtain ⟨request, clock, sources, entries, revisions, _, _, wire, _, admitted, authorized⟩ :=
    decideChecked_system allowed sound snapshot scope
  refine ⟨request, clock, sources, entries, revisions, wire, ?_⟩
  apply System.Reachable.step (trace_reachable reachable trace)
  refine System.Step.dispatch _ _ ?_ ?_ ?_ fresh
  · exact authorized
  · intro id used
    obtain ⟨entry, present, used⟩ := used
    have sourceH := authorized.2.2.2 entry present
    rw [used] at sourceH
    cases sourceH with
    | receipt _ _ _ record _ =>
      change receipts id = some (requests id).grant
      rw [record, grants _ _ record]
  · intro id used
    obtain ⟨entry, present, used⟩ := used
    exact transfer_claims_owned reachable complete trace admitted (evidence_entries wire)
      (checked_receipt_ids_valid allowed) present used

end VerifiedKernel.IFC.TransferSystem
