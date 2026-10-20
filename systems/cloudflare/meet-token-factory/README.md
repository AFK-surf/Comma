# Meet token factories

Two Cloudflare Workers supply Google Meet join credentials to the native Meeting runtime:

| Worker | Join mode | Source directory |
|---|---|---|
| `meet-master-token-factory` | Signed-in join: mints `ya29` tokens from a stored Android master token | `master-token-factory/` |
| `meet-guest-factory` | Guest join: headless Chrome captures the join RPC requests | `meetnative-tokenfactory/` |

The source is in [AFK-surf/meet_tokenfactory](https://github.com/AFK-surf/meet_tokenfactory).
Cue keeps only the deployment configuration:

- `source.lock.json`: the source repository and the revision to deploy.
- `master/wrangler.jsonc`, `guest/wrangler.jsonc`: the `staging` and `stable` environments.
  Paths point into `.source/`, where CI checks out the locked revision.

## Environments

| Worker | `staging` | `stable` |
|---|---|---|
| `meet-master-token-factory` | `https://meet-mtf-staging.afk.surf` (D1 `meet-mtf-staging`) | `https://meet-mtf-prod.afk.surf` (D1 `meet-mtf-stable`) |
| `meet-guest-factory` | `https://meet-guest-factory-staging.afk.surf/v1/handoff` | `https://meet-guest-factory-prod.afk.surf/v1/handoff` |

Both Workers use the secret `TOKENFACTORY_SECRET`. CI uploads it from the GitHub environment
secret `MEET_TOKENFACTORY_SECRET`.

## Release

`.github/workflows/meet-token-factory.yml` deploys the Workers. Do not deploy by hand.

1. Merge the change in `meet_tokenfactory` and note the merge commit.
2. In Cue, set `revision` in `source.lock.json` to that commit and open a pull request. CI
   builds both Container images and runs `wrangler deploy --dry-run` for both environments.
3. Merge the pull request into `main`. CI deploys `staging`:
   - For the master factory, it creates the D1 database if it does not exist and applies
     `schema.sql`.
   - It deploys with `wrangler deploy --secrets-file`.
   - The smoke test expects `401` without the secret. With the secret, it expects `200` from
     `GET /v1/accounts` (master) and `405` from `GET /v1/handoff` (guest).
4. A push to `prod` deploys `stable`.

Each deploy restarts the Durable Objects. A login or handoff that is in progress fails.

## Consumer

Salix `config.json` → `meetings`:

```jsonc
{
  "master_token_factory": {"base_url": "https://meet-mtf-staging.afk.surf", "secret": "…", "profile": "Default"},
  "guest_factory": {"url": "https://meet-guest-factory-staging.afk.surf/v1/handoff", "secret": "…"}
}
```

The first login for a profile, the HTTP interface and the security model are in the source
repository's `DEPLOY.md` files.
