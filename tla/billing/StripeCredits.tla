------------------------- MODULE StripeCredits -------------------------
(***************************************************************************)
(* Paid Stripe facts create grantable cycles. Provider retries may replay  *)
(* transitions, but a cycle is issued at most once. Refunds compensate only *)
(* the purchased grant and never make its remaining credits negative.       *)
(*                                                                         *)
(* Runtime anchors: BillingStripe.Events, BillingCommerce.Subscriptions,    *)
(* BillingCore.Credits.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Cycles, Plans, UnsafeIssueBeforePayment

ASSUME Cycles # {} /\ Plans # {} /\ UnsafeIssueBeforePayment \in BOOLEAN

VARIABLES paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan

vars == <<paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Init ==
  /\ paid = FALSE
  /\ due = {}
  /\ issued = {}
  /\ remaining = 2
  /\ refunded = 0
  /\ subscriptionStatus = "unknown"
  /\ currentPlan = CHOOSE p \in Plans : TRUE

InvoicePaid ==
  /\ ~paid
  /\ paid' = TRUE
  /\ due' = {CHOOSE c \in Cycles : TRUE}
  /\ subscriptionStatus' = "active"
  /\ UNCHANGED <<issued, remaining, refunded, currentPlan>>

CycleBecomesDue(c) ==
  /\ paid
  /\ c \notin due
  /\ due' = due \cup {c}
  /\ UNCHANGED <<paid, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Issue(c) ==
  /\ c \notin issued
  /\ IF UnsafeIssueBeforePayment THEN c \in Cycles ELSE c \in due /\ paid
  /\ issued' = issued \cup {c}
  /\ UNCHANGED <<paid, due, remaining, refunded, subscriptionStatus, currentPlan>>

ReplayIssue(c) ==
  /\ c \in issued
  /\ UNCHANGED vars

Cancel ==
  /\ subscriptionStatus # "canceled"
  /\ subscriptionStatus' = "canceled"
  /\ UNCHANGED <<paid, due, issued, remaining, refunded, currentPlan>>

ChangePlan(plan) ==
  /\ subscriptionStatus = "active"
  /\ plan \in Plans
  /\ plan # currentPlan
  /\ currentPlan' = plan
  /\ UNCHANGED <<paid, due, issued, remaining, refunded, subscriptionStatus>>

PartialRefund ==
  /\ paid
  /\ refunded = 0
  /\ refunded' = 1
  /\ remaining' = IF remaining > 0 THEN remaining - 1 ELSE 0
  /\ UNCHANGED <<paid, due, issued, subscriptionStatus, currentPlan>>

FullRefund ==
  /\ paid
  /\ refunded < 2
  /\ refunded' = 2
  /\ remaining' = 0
  /\ UNCHANGED <<paid, due, issued, subscriptionStatus, currentPlan>>

Next ==
  \/ InvoicePaid
  \/ \E c \in Cycles : CycleBecomesDue(c)
  \/ \E c \in Cycles : Issue(c)
  \/ \E c \in Cycles : ReplayIssue(c)
  \/ Cancel
  \/ \E plan \in Plans : ChangePlan(plan)
  \/ PartialRefund
  \/ FullRefund

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ paid \in BOOLEAN
  /\ due \subseteq Cycles
  /\ issued \subseteq Cycles
  /\ remaining \in 0..2
  /\ refunded \in 0..2
  /\ subscriptionStatus \in {"unknown", "active", "canceled"}
  /\ currentPlan \in Plans

NoGrantBeforePayment == issued # {} => paid
IssuedOnlyWhenDue == issued \subseteq due
RefundNeverIncreasesCredits == remaining + refunded <= 2

Safety == TypeOK /\ NoGrantBeforePayment /\ IssuedOnlyWhenDue /\ RefundNeverIncreasesCredits

=============================================================================
