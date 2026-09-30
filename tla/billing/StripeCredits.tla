------------------------- MODULE StripeCredits -------------------------
(***************************************************************************)
(* Paid Stripe facts create grantable cycles. Provider retries may replay  *)
(* transitions, but each cycle/payment allocation issues at most once.    *)
(* Refunds and disputes affect only this payment and never negative credits. *)
(*                                                                         *)
(* Runtime anchors: BillingStripe.Events, BillingCommerce.Subscriptions,    *)
(* BillingCore.Credits.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Cycles, Plans, UnsafeIssueBeforePayment

ASSUME Cycles # {} /\ Plans # {} /\ UnsafeIssueBeforePayment \in BOOLEAN

VARIABLES paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan, held

vars == <<paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan, held>>

Init ==
  /\ held = FALSE
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
  /\ UNCHANGED <<held, issued, remaining, refunded, currentPlan>>

CycleBecomesDue(c) ==
  /\ paid
  /\ c \notin due
  /\ due' = due \cup {c}
  /\ UNCHANGED <<held, paid, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Issue(c) ==
  /\ c \notin issued
  /\ IF UnsafeIssueBeforePayment THEN c \in Cycles ELSE c \in due /\ paid /\ ~held /\ refunded < 2
  /\ issued' = issued \cup {c}
  /\ UNCHANGED <<held, paid, due, remaining, refunded, subscriptionStatus, currentPlan>>

ReplayIssue(c) ==
  /\ c \in issued
  /\ UNCHANGED vars

Cancel ==
  /\ subscriptionStatus # "canceled"
  /\ subscriptionStatus' = "canceled"
  /\ UNCHANGED <<held, paid, due, issued, remaining, refunded, currentPlan>>

ChangePlan(plan) ==
  /\ subscriptionStatus = "active"
  /\ plan \in Plans
  /\ plan # currentPlan
  /\ currentPlan' = plan
  /\ UNCHANGED <<held, paid, due, issued, remaining, refunded, subscriptionStatus>>

PartialRefund ==
  /\ paid
  /\ refunded = 0
  /\ refunded' = 1
  /\ remaining' = remaining
  /\ UNCHANGED <<held, paid, due, issued, subscriptionStatus, currentPlan>>

FullRefund ==
  /\ paid
  /\ refunded < 2
  /\ refunded' = 2
  /\ remaining' = 0
  /\ UNCHANGED <<held, paid, due, issued, subscriptionStatus, currentPlan>>

DisputeHold ==
  /\ paid
  /\ ~held
  /\ held' = TRUE
  /\ UNCHANGED <<paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan>>

DisputeWin ==
  /\ held
  /\ held' = FALSE
  /\ UNCHANGED <<paid, due, issued, remaining, refunded, subscriptionStatus, currentPlan>>

Consume ==
  /\ paid /\ ~held /\ remaining > 0
  /\ remaining' = remaining - 1
  /\ UNCHANGED <<paid, due, issued, refunded, subscriptionStatus, currentPlan, held>>

Next ==
  \/ InvoicePaid
  \/ \E c \in Cycles : CycleBecomesDue(c)
  \/ \E c \in Cycles : Issue(c)
  \/ \E c \in Cycles : ReplayIssue(c)
  \/ Cancel
  \/ \E plan \in Plans : ChangePlan(plan)
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

NoGrantBeforePayment == issued # {} => paid
IssuedOnlyWhenDue == issued \subseteq due
RefundNeverIncreasesCredits == remaining <= 2 /\ (refunded = 2 => remaining = 0)

Safety == TypeOK /\ NoGrantBeforePayment /\ IssuedOnlyWhenDue /\ RefundNeverIncreasesCredits

=============================================================================
