# OAuth IdP routine key rotation model

`OauthIdpRoutineRotation.tla` models the timed two-step routine rotation
from `docs/identity-security.md`.

Inside Comma the signing-key set is one shared database table
(`comma_oauth_signing_keys`), so all pods are instantly consistent and need
no protocol. The protocol exists for **relying parties**: their JWKS
caches refresh on their own clock, bounded by the v1 integration contract
(max cache age 10 minutes plus refresh cooldown; panva/jose's defaults sit
inside that bound). Activating a key that RP caches have never seen breaks
verification of every newly issued token at those RPs — the failure the
fifth review round reproduced against single-step rotation.

The two steps, with their code anchors:

| Step        | Code                                                                                        | Model                                      |
| ----------- | ------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Pre-publish | `SigningKeys.prepublish!/0` — pair inserted `pending`, public half in the JWKS immediately  | `Prepublish`                               |
| Activate    | `SigningKeys.activate!/0` — guard refuses until published for `rotation_prepublish_seconds` | `Activate` with the `PrepublishWait` guard |

The guard is checked against `created_at` in the shared database:
enforcement by data, not operator discipline.

Safety property `RpCacheHasNewKeyWhenItSigns`: once activation happens,
every contract-honoring RP cache (age ≤ `MaxCacheAge`, forced by `Tick`)
was necessarily fetched **strictly after** pre-publish and therefore
contains the new key. Membership is strict (`rpFetchedAt >
prepublishedAt`): a fetch in the same instant as publication may have
observed the JWKS just before the key appeared, so safety requires a
strict margin `PrepublishWait > MaxCacheAge` — which the code has
(630-second wait over the 600-second contractual cache bound).
Configurations:

- `OauthIdpRoutineRotation_Safety` — `PrepublishWait > MaxCacheAge`;
  expected to pass.
- `OauthIdpRoutineRotation_UnsafeImmediateActivate` — `PrepublishWait = 0`
  (single-step rotation, fifth review); expected counterexample: an RP
  cache fetched just before the rotation misses the new kid.
- `OauthIdpRoutineRotation_UnsafeEqualWait` — `PrepublishWait =
MaxCacheAge` (sixth review's boundary): the same-instant fetch makes
  the equality margin insufficient; expected counterexample.

No liveness is claimed: both steps are operator commands. Emergency
rotation (`rotate_compromised!/0`) is deliberately out of scope — it is a
single transaction whose RP-cache verification gap is documented and
accepted in the runbook, not ordered around. The `retire_after` guard on
routine removal is a pure data-timestamp comparison with no distributed
ordering, covered by ExUnit.

Run locally:

```bash
tla/oauth_idp_key_rotation/check.sh
```
