# OAuth IdP routine key rotation model

`OauthIdpRoutineRotation.tla` models the timed two-step routine rotation
from [identity and security](../../docs/identity-security.md).

All Comma pods share one signing-key table (`comma_oauth_signing_keys`), so
the protocol exists for **relying parties** (RPs). RP JWKS caches refresh on
their own clock, bounded by the v1 integration contract (max cache age 10
minutes plus refresh cooldown). If a key becomes active before RP caches have
seen it, those RPs cannot verify any newly issued token.

| Step        | Code                                                                                        | Model                                      |
| ----------- | ------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Pre-publish | `SigningKeys.prepublish!/0`: pair inserted `pending`, public half in the JWKS immediately   | `Prepublish`                               |
| Activate    | `SigningKeys.activate!/0`: guard refuses until published for `rotation_prepublish_seconds`  | `Activate` with the `PrepublishWait` guard |

The guard compares against `created_at` in the shared database, so data
enforces it, not operator discipline.

Safety property `RpCacheHasNewKeyWhenItSigns`: once activation happens, every contract-honoring
RP cache (age at most `MaxCacheAge`, forced by `Tick`) was fetched **strictly
after** pre-publish and contains the new key. A fetch in the same instant as
publication can miss the key, so safety needs `PrepublishWait > MaxCacheAge`.
The code default waits 630 seconds over the 600-second contractual cache bound.

Configurations:

- `OauthIdpRoutineRotation_Safety`: `PrepublishWait > MaxCacheAge`. Expected to pass.
- `OauthIdpRoutineRotation_UnsafeImmediateActivate`: `PrepublishWait = 0`
  (single-step rotation). Expected counterexample: an RP cache fetched just
  before the rotation misses the new kid.
- `OauthIdpRoutineRotation_UnsafeEqualWait`: `PrepublishWait = MaxCacheAge`.
  Expected counterexample: the same-instant fetch makes the equal margin
  insufficient.

No liveness is claimed because both steps are operator commands. Emergency
rotation (`rotate_compromised!/0`) is out of scope. Its RP-cache verification
gap is documented and accepted in the runbook. ExUnit covers the `retire_after`
guard on routine removal.

Run locally:

```bash
tla/oauth_idp_key_rotation/check.sh
```
