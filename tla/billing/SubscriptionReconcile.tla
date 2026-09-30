---------------------- MODULE SubscriptionReconcile ----------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS Workers, UnsafeEventSnapshot
VARIABLES provider, applied, owner, phase, event, snapshot, regressed
vars == <<provider, applied, owner, phase, event, snapshot, regressed>>

(* BillingStripe.Events / BillingCommerce.Subscriptions:
   invoice and lifecycle requests take the same subscription row lock before
   reading Stripe. Revisions abstract successive status/plan states; they are
   NOT persisted by the implementation. Stripe's read is authoritative at
   some instant during the request. Delayed/duplicate events carry any old
   revision; only the unsafe implementation applies that payload directly.
   The SQL lock spans read and commit. Disconnect/timeout/restart abort it.
   Provider availability or event delivery fairness is not assumed; no
   liveness is claimed. Paid cycle effects are modeled in StripeCredits. *)
Init ==
  /\ provider = 1 /\ applied = 0 /\ owner = "none"
  /\ phase = [w \in Workers |-> "idle"]
  /\ event = [w \in Workers |-> 1]
  /\ snapshot = [w \in Workers |-> 0]
  /\ regressed = FALSE
ChangeProvider ==
  /\ provider < 3 /\ provider' = provider + 1
  /\ UNCHANGED <<applied, owner, phase, event, snapshot, regressed>>
Deliver(w, rev) ==
  /\ phase[w] = "idle" /\ rev \in 1..provider
  /\ event' = [event EXCEPT ![w] = rev]
  /\ phase' = [phase EXCEPT ![w] = "waiting"]
  /\ UNCHANGED <<provider, applied, owner, snapshot, regressed>>
Lock(w) ==
  /\ phase[w] = "waiting" /\ owner = "none"
  /\ owner' = w /\ phase' = [phase EXCEPT ![w] = "reading"]
  /\ UNCHANGED <<provider, applied, event, snapshot, regressed>>
Read(w) ==
  /\ owner = w /\ phase[w] = "reading"
  /\ snapshot' = [snapshot EXCEPT ![w] = IF UnsafeEventSnapshot THEN event[w] ELSE provider]
  /\ phase' = [phase EXCEPT ![w] = "ready"]
  /\ UNCHANGED <<provider, applied, owner, event, regressed>>
Commit(w) ==
  /\ owner = w /\ phase[w] = "ready"
  /\ regressed' = (regressed \/ (snapshot[w] < applied))
  /\ applied' = snapshot[w]
  /\ owner' = "none" /\ phase' = [phase EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<provider, event, snapshot>>
Abort(w) ==
  /\ phase[w] # "idle"
  /\ owner' = IF owner = w THEN "none" ELSE owner
  /\ phase' = [phase EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<provider, applied, event, snapshot, regressed>>
Next ==
  \/ ChangeProvider
  \/ \E w \in Workers, rev \in 1..3 : Deliver(w, rev)
  \/ \E w \in Workers : Lock(w) \/ Read(w) \/ Commit(w) \/ Abort(w)
Spec == Init /\ [][Next]_vars
Safety ==
  /\ provider \in 1..3 /\ applied \in 0..provider
  /\ owner \in Workers \cup {"none"}
  /\ phase \in [Workers -> {"idle", "waiting", "reading", "ready"}]
  /\ event \in [Workers -> 1..3] /\ snapshot \in [Workers -> 0..3]
  /\ ~regressed
=============================================================================
