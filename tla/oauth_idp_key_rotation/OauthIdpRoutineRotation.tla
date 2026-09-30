------------------- MODULE OauthIdpRoutineRotation -------------------
(***************************************************************************)
(* The timed two-step routine rotation of the Comma OAuth IdP signing key   *)
(* (docs/identity-security.md).                       *)
(*                                                                        *)
(* Inside Comma the key set is one shared table, so every pod is           *)
(* instantly consistent — pods need no protocol. The protocol exists     *)
(* for RELYING PARTIES: their JWKS caches refresh on their own clock,    *)
(* bounded contractually (v1 integration contract: max cache age 10      *)
(* minutes + refresh cooldown). Activating a key that RP caches have     *)
(* never seen breaks verification of every new token at those RPs.       *)
(*                                                                        *)
(* Code anchors (bidirectional):                                          *)
(*   - Prepublish is SigningKeys.prepublish!/0: the pair is inserted      *)
(*     status=pending and its public half joins the JWKS immediately.    *)
(*   - Activate is SigningKeys.activate!/0, whose guard refuses until    *)
(*     the pending key has been published for rotation_prepublish_seconds *)
(*     (PrepublishWait here). That guard is checked against created_at   *)
(*     in the shared database — enforcement by data, not by operator     *)
(*     discipline.                                                        *)
(*   - The RP contract (max cache age) is MaxCacheAge: the Tick action   *)
(*     forces a refetch before a cache exceeds it. panva/jose's defaults *)
(*     (10-minute cache, 30-second cooldown) sit inside this bound.      *)
(*                                                                        *)
(* The safety property: once activation happens, every                    *)
(* contract-honoring RP cache already contains the new key. Cache        *)
(* membership is STRICT (rpFetchedAt > prepublishedAt): a fetch in the   *)
(* same instant as publication may have observed the JWKS just before    *)
(* the key appeared, so it must not count — the sixth review showed the  *)
(* non-strict version passing on exactly that pre-publication fetch.     *)
(* Safety therefore requires a strict margin PrepublishWait >            *)
(* MaxCacheAge, which the code has: 630s wait over a 600s contractual    *)
(* cache bound. Two expected counterexamples pin the boundary: the       *)
(* single-step rotation (PrepublishWait = 0, fifth review) and the       *)
(* exact-equality wait (PrepublishWait = MaxCacheAge, sixth review).     *)
(*                                                                        *)
(* No liveness is claimed: both steps are operator commands. Emergency   *)
(* rotation (rotate_compromised!/0) is deliberately out of scope: it is  *)
(* a single transaction whose RP-cache verification gap is documented    *)
(* and accepted, not ordered around.                                     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxCacheAge, PrepublishWait, MaxTime

VARIABLES now, prepublishedAt, activatedAt, rpFetchedAt

vars == <<now, prepublishedAt, activatedAt, rpFetchedAt>>

None == 0 - 1

Init == /\ now = 0
        /\ prepublishedAt = None
        /\ activatedAt = None
        /\ rpFetchedAt = 0

(* Time advances; the RP may refetch at any tick and MUST refetch       *)
(* before its cache exceeds the contractual MaxCacheAge.                *)
Tick == /\ now < MaxTime
        /\ now' = now + 1
        /\ \E fetch \in {rpFetchedAt, now + 1} :
             /\ (now + 1) - fetch <= MaxCacheAge
             /\ rpFetchedAt' = fetch
        /\ UNCHANGED <<prepublishedAt, activatedAt>>

Prepublish == /\ prepublishedAt = None
              /\ prepublishedAt' = now
              /\ UNCHANGED <<now, activatedAt, rpFetchedAt>>

(* activate!/0's guard: the pending key must have been published for at *)
(* least PrepublishWait before it may sign.                             *)
Activate == /\ prepublishedAt # None
            /\ activatedAt = None
            /\ now >= prepublishedAt + PrepublishWait
            /\ activatedAt' = now
            /\ UNCHANGED <<now, prepublishedAt, rpFetchedAt>>

Next == Tick \/ Prepublish \/ Activate

Spec == Init /\ [][Next]_vars

(* An RP cache contains the new key iff it was fetched STRICTLY after   *)
(* pre-publish: a same-instant fetch may predate the key's appearance.  *)
(* Once the key signs, the (contract-honoring) RP cache must already    *)
(* contain it.                                                          *)
RpCacheHasNewKeyWhenItSigns ==
  activatedAt # None => rpFetchedAt > prepublishedAt

=========================================================================
