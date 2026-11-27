------------------------- MODULE StripeCredits -------------------------
(***************************************************************************)
(* Paid provider facts (Stripe, App Store, Google Play) create grantable   *)
(* cycles. Provider retries may replay transitions, but each cycle/payment *)
(* allocation issues at most once. Refunds and disputes affect only this   *)
(* payment and never negative credits. A store replacement ends the old    *)
(* period: its unissued cycles never issue.                                *)
(*                                                                         *)
(* Runtime anchors: BillingStripe.Events, BillingCommerce.Subscriptions,    *)
(* BillingCommerce.PaidCycles, BillingCore.Credits.                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Cycles, Plans, UnsafeIssueBeforePayment, UnsafeIssueReplaced

ASSUME Cycles # {} /\ Plans # {} /\ UnsafeIssueBeforePayment \in BOOLEAN
ASSUME UnsafeIssueReplaced \in BOOLEAN

VARIABLES paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan, held, replaced

vars == <<paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan, held, replaced>>

Init ==
  /\ held = FALSE
  /\ paid = FALSE
  /\ due = {}
  /\ issued = {}
  /\ remaining = 2
  /\ refunded = 0
  /\ subscriptionStatus = "unknown"
  /\ currentPlan = CHOOSE p \in Plans : TRUE
  /\ replaced = {}

InvoicePaid ==
  /\ ~paid
  /\ paid' = TRUE
  /\ due' = {CHOOSE c \in Cycles : TRUE}
  /\ subscriptionStatus' = "active"
  /\ UNCHANGED <<replaced, held, issued, remaining, refunded, currentPlan>>

CycleBecomesDue(c) ==
  /\ paid
  /\ c \notin due
  /\ due' = due \cup {c}
  /\ UNCHANGED <<replaced, held, paid, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Issue(c) ==
  /\ c \notin issued
  /\ UnsafeIssueReplaced \/ c \notin replaced
  /\ IF UnsafeIssueBeforePayment THEN c \in Cycles ELSE c \in due /\ paid /\ ~held /\ refunded < 2
  /\ issued' = issued \cup {c}
  /\ UNCHANGED <<replaced, held, paid, due, remaining, refunded, subscriptionStatus, currentPlan>>

ReplayIssue(c) ==
  /\ c \in issued
  /\ UNCHANGED vars

Cancel ==
  /\ subscriptionStatus # "canceled"
  /\ subscriptionStatus' = "canceled"
  /\ UNCHANGED <<replaced, held, paid, due, issued, remaining, refunded, currentPlan>>

ChangePlan(plan) ==
  /\ subscriptionStatus = "active"
  /\ plan \in Plans
  /\ plan # currentPlan
  /\ currentPlan' = plan
  /\ UNCHANGED <<replaced, held, paid, due, issued, remaining, refunded, subscriptionStatus>>

\* PaidCycles.replace!: a store upgrade or immediate change starts a new
\* period. The old payment's unissued cycles become `replaced`; issued
\* grants keep their credits. The new period is a new payment allocation.
Replace(plan) ==
  /\ paid /\ subscriptionStatus = "active"
  /\ plan \in Plans /\ plan # currentPlan
  /\ replaced' = replaced \cup (Cycles \ issued)
  /\ currentPlan' = plan
  /\ UNCHANGED <<held, paid, due, issued, remaining, refunded, subscriptionStatus>>

PartialRefund ==
  /\ paid
  /\ refunded = 0
  /\ refunded' = 1
  /\ remaining' = remaining
  /\ UNCHANGED <<replaced, held, paid, due, issued, subscriptionStatus, currentPlan>>

FullRefund ==
  /\ paid
  /\ refunded < 2
  /\ refunded' = 2
  /\ remaining' = 0
  /\ UNCHANGED <<replaced, held, paid, due, issued, subscriptionStatus, currentPlan>>

DisputeHold ==
  /\ paid
  /\ ~held
  /\ held' = TRUE
  /\ UNCHANGED <<replaced, paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan>>

DisputeWin ==
  /\ held
  /\ held' = FALSE
  /\ UNCHANGED <<replaced, paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Consume ==
  /\ paid /\ ~held /\ remaining > 0
  /\ remaining' = remaining - 1
  /\ UNCHANGED <<replaced, paid, due, issued, refunded, subscriptionStatus, currentPlan, held>>

Next ==
  \/ InvoicePaid
  \/ \E c \in Cycles : CycleBecomesDue(c)
  \/ \E c \in Cycles : Issue(c)
  \/ \E c \in Cycles : ReplayIssue(c)
  \/ Cancel
  \/ \E plan \in Plans : ChangePlan(plan)
  \/ \E plan \in Plans : Replace(plan)
  \/ PartialRefund
  \/ FullRefund
  \/ DisputeHold
  \/ DisputeWin
  \/ Consume

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ held \in BOOLEAN
  /\ paid \in BOOLEAN
  /\ due \subseteq Cycles
  /\ issued \subseteq Cycles
  /\ remaining \in 0..2
  /\ refunded \in 0..2
  /\ subscriptionStatus \in {"unknown", "active", "canceled"}
  /\ currentPlan \in Plans
  /\ replaced \subseteq Cycles

NoGrantBeforePayment == issued # {} => paid
IssuedOnlyWhenDue == issued \subseteq due
RefundNeverIncreasesCredits == remaining <= 2 /\ (refunded = 2 => remaining = 0)
ReplacedNeverIssues == replaced \cap issued = {}

Safety ==
  /\ TypeOK /\ NoGrantBeforePayment /\ IssuedOnlyWhenDue /\ RefundNeverIncreasesCredits
  /\ ReplacedNeverIssues

=============================================================================
