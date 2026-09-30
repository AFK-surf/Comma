import VerifiedKernelProofs.IFC.Model

/-! Authorization proofs and receipt/dispatch protocol over the shared IFC definitions. -/
namespace VerifiedKernel.IFC.System
variable [Domain]

abbrev AttemptId := Nat

def Join (a b : Label) : Label := a ++ b

def JoinLabels (inputs : List Label) : Label := inputs.flatten

/-- This proof premise covers actual content dependencies. It is not an LLM property. -/
def SourcesComplete (actualSources : List Label) (evidence : List Admission) : Prop :=
  ∀ src ∈ actualSources, ∃ entry ∈ evidence, entry.item.label = src

theorem reads_join : Reads w p (Join a b) ↔ Reads w p a ∧ Reads w p b := by
  simp [Reads, Join, List.mem_append, or_imp, forall_and]

theorem flow_refl : Flows w l l := fun _ h => h

theorem flow_trans (hab : Flows w a b) (hbc : Flows w b c) : Flows w a c :=
  fun p h => hab p (hbc p h)

theorem join_flows : Flows w (Join a b) d ↔ Flows w a d ∧ Flows w b d := by
  constructor
  · intro h
    exact ⟨fun p hp => (reads_join.mp (h p hp)).1,
      fun p hp => (reads_join.mp (h p hp)).2⟩
  · rintro ⟨ha, hb⟩ p hp
    exact reads_join.mpr ⟨ha p hp, hb p hp⟩

theorem join_comm : Reads w p (Join a b) ↔ Reads w p (Join b a) := by
  simp only [reads_join, and_comm]

theorem join_assoc : Reads w p (Join (Join a b) c) ↔ Reads w p (Join a (Join b c)) := by
  simp only [reads_join, and_assoc]

theorem join_idem : Reads w p (Join a a) ↔ Reads w p a := by
  simp only [reads_join, and_self]

theorem join_labels_preserves_sources (hl : l ∈ inputs) : Flows w l (JoinLabels inputs) := by
  intro p hp atom ha
  exact hp atom (List.mem_flatten.mpr ⟨l, hl, ha⟩)

theorem source_authority (h : SourceAuthorized w policy a e src receipts now clause) :
    Flows w src e.destination ∨ (Unsealed policy src ∧ Reads w a.requester src) := by
  cases h with
  | flow h => exact Or.inl h
  | inPlace hu hr _ _ | instruction hu hr _ | receipt hu hr _ _ _ => exact Or.inr ⟨hu, hr⟩

theorem sealed_requires_flow
    (h : SourceAuthorized w policy a e src receipts now clause)
    (hs : ∃ atom ∈ src, policy.sealed atom) : Flows w src e.destination := by
  rcases source_authority h with flow | ⟨unsealed, _⟩
  · exact flow
  · obtain ⟨atom, ha, hs⟩ := hs
    exact False.elim (unsealed atom ha hs)

theorem context_resolves (h : Resolves ctx .context selected) :
    ∀ item, item ∈ selected ↔ item ∈ ctx := h

theorem explicit_empty_resolves : Resolves ctx (.explicit []) [] := by
  simp [Resolves]

theorem authorized_sources (h : Authorized w policy ctx a e receipts now gates evidence) :
    ∀ entry ∈ evidence, Flows w entry.item.label e.destination ∨
      (Unsealed policy entry.item.label ∧ Reads w a.requester entry.item.label) :=
  fun entry he => source_authority (h.2.2.2 entry he)

theorem actual_sources_authorized
    (h : Authorized w policy ctx a e receipts now gates evidence)
    (complete : SourcesComplete actualSources evidence) :
    ∀ src ∈ actualSources, Flows w src e.destination ∨
      (Unsealed policy src ∧ Reads w a.requester src) := by
  intro src hs
  obtain ⟨entry, he, rfl⟩ := complete src hs
  exact authorized_sources h entry he

/- One consent request, with no finite bound on event count, actors or attempts.
Settlement and mint are separate writes. Mint permission belongs to the CAS
winner and is lost on a crash. The owner is ghost history of the atomic delete. -/
namespace Consent

inductive Status where
  | pending | approved | denied
  deriving DecidableEq

structure Request where
  grant : Receipt
  deadline : Nat

structure State where
  status : Status := .pending
  mintPermit : Bool := false
  available : Bool := false
  owner : Option AttemptId := none
  minted : Nat := 0
  claims : Nat := 0

inductive Event where
  | approve (actor : Principal) (now : Nat)
  | deny (actor : Principal) (now : Nat)
  | mint
  | consume (attempt : AttemptId)
  | crash
  | prune

def step (r : Request) (s : State) : Event → State
  | .approve actor now =>
      if s.status = .pending ∧ actor = r.grant.requester ∧ now < r.deadline then
        { s with status := .approved, mintPermit := true }
      else s
  | .deny actor now =>
      if s.status = .pending ∧ actor = r.grant.requester ∧ now < r.deadline then
        { s with status := .denied }
      else s
  | .mint =>
      if s.mintPermit then
        { s with mintPermit := false, available := true, minted := s.minted + 1 }
      else s
  | .consume attempt =>
      if s.available then
        { s with available := false, owner := some attempt, claims := s.claims + 1 }
      else s
  | .crash => { s with mintPermit := false }
  | .prune => { s with available := false }

def bit (b : Bool) : Nat := if b then 1 else 0

def Safe (s : State) : Prop :=
  bit s.mintPermit + s.minted ≤ (if s.status = .approved then 1 else 0) ∧
  bit s.available + s.claims ≤ s.minted ∧
  (s.owner = none ↔ s.claims = 0)

omit [Domain] in
theorem initial_safe : Safe ({} : State) := by simp [Safe, bit]

theorem step_safe (h : Safe s) : Safe (step r s event) := by
  rcases s with ⟨status, mintPermit, available, owner, minted, claims⟩
  cases event <;> cases status <;> cases mintPermit <;> cases available <;>
    simp_all [Safe, step, bit] <;> first | omega | (split <;> simp_all <;> omega)

def run (r : Request) : State → List Event → State
  | s, [] => s
  | s, event :: rest => run r (step r s event) rest

theorem run_safe (h : Safe s) : Safe (run r s events) := by
  induction events generalizing s with
  | nil => exact h
  | cons event rest ih => exact ih (step_safe h)

theorem all_traces_safe : Safe (run r {} events) := run_safe initial_safe

omit [Domain] in
theorem single_use (h : Safe s) : s.claims ≤ 1 ∧ s.minted ≤ 1 := by
  obtain ⟨h1, h2, _⟩ := h
  split at h1 <;> omega

theorem settlement_final (hs : s.status ≠ .pending) :
    (step r s event).status = s.status := by
  cases event <;> simp [step, hs] <;> split <;> rfl

theorem settled_run_final (hs : s.status ≠ .pending) :
    (run r s events).status = s.status := by
  induction events generalizing s with
  | nil => rfl
  | cons event rest ih =>
    have stable := settlement_final (r := r) (event := event) hs
    exact (ih (by simpa [stable] using hs)).trans stable

theorem unauthorized_answer_ignored (hactor : actor ≠ r.grant.requester) :
    step r s (.approve actor now) = s ∧ step r s (.deny actor now) = s := by
  simp [step, hactor]

theorem expired_answer_ignored (hexp : r.deadline ≤ now) :
    step r s (.approve actor now) = s ∧ step r s (.deny actor now) = s := by
  have h : ¬ now < r.deadline := by omega
  simp [step, h]

theorem owner_stable (hs : Safe s) (ho : s.owner = some attempt) :
    (step r s event).owner = some attempt := by
  have unavailable : s.available = false := by
    obtain ⟨h1, h2, h3⟩ := hs
    have nonzero : s.claims ≠ 0 := by simp_all
    have bounds := single_use ⟨h1, h2, h3⟩
    cases hav : s.available <;> simp_all [bit] <;> omega
  cases event <;> simp [step, unavailable, ho] <;> split <;> simp_all

omit [Domain] in
theorem claim_requires_approval (h : Safe s) (ho : s.owner = some attempt) :
    s.status = .approved := by
  obtain ⟨h1, h2, h3⟩ := h
  have nonzero : s.claims ≠ 0 := by simp_all
  split at h1 <;> omega

end Consent

/-- An admission records the world and time used by the decision. Membership
changes after it do not rewrite history. Receipt consumption has its own state. -/
structure Dispatch where
  attempt : AttemptId
  world : World
  policy : Policy
  context : List Item
  activation : Activation
  effect : Effect
  receipts : ReceiptId → Option Receipt
  now : Nat
  gates : Gates
  evidence : List Admission

def Dispatch.Authorized (d : Dispatch) : Prop :=
  System.Authorized d.world d.policy d.context d.activation d.effect d.receipts d.now d.gates d.evidence

def Uses (d : Dispatch) (id : ReceiptId) : Prop :=
  ∃ entry ∈ d.evidence, entry.clause = .receipt id

structure State where
  ledger : ReceiptId → Consent.State := fun _ => {}
  dispatched : List Dispatch := []

inductive Step (requests : ReceiptId → Consent.Request) : State → State → Prop where
  | receipt (s : State) (id : ReceiptId) (event : Consent.Event) :
      Step requests s { s with ledger := fun key =>
        if key = id then Consent.step (requests id) (s.ledger id) event else s.ledger key }
  | dispatch (s : State) (d : Dispatch)
      (authorized : d.Authorized)
      (bound : ∀ id, Uses d id → d.receipts id = some (requests id).grant)
      (claimed : ∀ id, Uses d id → (s.ledger id).owner = some d.attempt)
      (fresh : ∀ old ∈ s.dispatched, old.attempt ≠ d.attempt) :
      Step requests s { s with dispatched := d :: s.dispatched }

def Safe (requests : ReceiptId → Consent.Request) (s : State) : Prop :=
  (∀ id, Consent.Safe (s.ledger id)) ∧
  (∀ d ∈ s.dispatched, d.Authorized ∧
    ∀ id, Uses d id → d.receipts id = some (requests id).grant ∧
      (s.ledger id).owner = some d.attempt)

theorem initial_safe : Safe requests ({} : State) := by
  exact ⟨fun _ => Consent.initial_safe, by simp⟩

theorem step_safe (h : Safe requests s) (hs : Step requests s next) : Safe requests next := by
  obtain ⟨ledgerSafe, dispatchSafe⟩ := h
  cases hs with
  | receipt id event =>
    constructor
    · intro key
      by_cases hk : key = id
      · subst key; simpa using Consent.step_safe (r := requests id) (event := event) (ledgerSafe id)
      · simpa [hk] using ledgerSafe key
    · intro d hd
      obtain ⟨ha, hc⟩ := dispatchSafe d hd
      refine ⟨ha, ?_⟩
      intro key hu
      refine ⟨(hc key hu).1, ?_⟩
      by_cases hk : key = id
      · subst key
        simpa using Consent.owner_stable (r := requests id) (event := event) (ledgerSafe id) (hc id hu).2
      · simpa [hk] using (hc key hu).2
  | dispatch d authorized bound claimed fresh =>
    refine ⟨ledgerSafe, ?_⟩
    intro old ho
    rcases List.mem_cons.mp ho with rfl | ho
    · exact ⟨authorized, fun id hu => ⟨bound id hu, claimed id hu⟩⟩
    · exact dispatchSafe old ho

inductive Reachable (requests : ReceiptId → Consent.Request) : State → Prop where
  | initial : Reachable requests {}
  | step : Reachable requests s → Step requests s next → Reachable requests next

theorem reachable_safe (h : Reachable requests s) : Safe requests s := by
  induction h with
  | initial => exact initial_safe
  | step _ hs ih => exact step_safe ih hs

theorem dispatch_authorized (h : Reachable requests s) (hd : d ∈ s.dispatched) :
    d.Authorized := (reachable_safe h).2 d hd |>.1

theorem receipt_not_shared {id : ReceiptId} (h : Reachable requests s)
    (ha : a ∈ s.dispatched) (hb : b ∈ s.dispatched)
    (ua : Uses a id) (ub : Uses b id) : a.attempt = b.attempt := by
  have safe := reachable_safe h
  have ca := ((safe.2 a ha).2 id ua).2
  have cb := ((safe.2 b hb).2 id ub).2
  exact Option.some.inj (ca.symm.trans cb)

theorem dispatch_receipt_approved {id : ReceiptId} (h : Reachable requests s)
    (hd : d ∈ s.dispatched) (hu : Uses d id) :
    d.receipts id = some (requests id).grant ∧ (s.ledger id).status = .approved := by
  have safe := reachable_safe h
  have bound := (safe.2 d hd).2 id hu
  exact ⟨bound.1, Consent.claim_requires_approval (safe.1 id) bound.2⟩

theorem dispatch_attempts_unique (h : Reachable requests s) :
    (s.dispatched.map Dispatch.attempt).Nodup := by
  induction h with
  | initial => simp
  | step _ hs ih =>
    cases hs with
    | receipt => exact ih
    | dispatch d _ _ _ fresh =>
      simp only [List.map_cons, List.nodup_cons]
      refine ⟨?_, ih⟩
      intro hm
      obtain ⟨old, ho, he⟩ := List.mem_map.mp hm
      exact fresh old ho he

end VerifiedKernel.IFC.System
