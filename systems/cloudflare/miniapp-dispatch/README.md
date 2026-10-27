# Mini App dispatch Workers

This package holds the Cloudflare side of Mini App backends (design: AFK-surf/Cue#4070, §6.3 and §8).

| Part | Source | Worker name (staging / stable) |
| --- | --- | --- |
| Dispatch Worker | `src/index.ts`, `wrangler.jsonc` | `miniapp-dispatch-staging` / `miniapp-dispatch-stable` |
| Outbound Worker | `src/outbound.ts`, `outbound/wrangler.jsonc` | `miniapp-outbound-staging` / `miniapp-outbound-stable` |
| App storage module | `src/app-storage.ts` → `systems/apps/comma_core/priv/mini_apps/app-storage.js` | uploaded by the Comma server as `app-<slug>-data` |

App scripts live in the Workers for Platforms dispatch namespace `comma-miniapps-staging` or `comma-miniapps-stable`.
The Comma server uploads them. CI deploys only the two Workers in this package.

## Dispatch Worker

The dispatch Worker is the only entry to app scripts. It has two routes:

- `GET /healthz` returns `{ok: true, version}`.
- `<METHOD> /internal/v1/apps/<script>/<path>` runs Version script `<script>` (`app-<slug>-v<n>`) with `/<path>` and the query string.

Every other path returns 404.

The Comma server signs each request with the `salix-vm-gateway` scheme and the shared secret `MINIAPP_DISPATCH_SECRET`:
`x-salix-signature: sha256=<hex HMAC-SHA256 of [METHOD, pathname+search, timestamp, nonce, sha256hex(body)].join("\n")>`,
with `x-salix-timestamp` (Unix seconds, at most 300 s skew), `x-salix-nonce` (used once) and `x-salix-request-id`.
A missing secret, a bad or stale signature, or a used nonce returns 404 `{"error": "not_found"}`.
The Worker logs the reason as `miniapp_dispatch_refused`.

The server also sends these headers:

| Header | Use |
| --- | --- |
| `x-comma-app-method` | Method of the app request: `GET`, `POST`, `PUT`, `PATCH` or `DELETE`. |
| `x-comma-app-version` | Version number. The app receives it. |
| `x-comma-viewer` | Pairwise viewer ID. The app receives it. |
| `x-comma-app-egress` | Comma-separated egress hosts of the Version manifest (at most 20). |

The Worker calls the script with limits `{cpuMs: 50, subRequests: 50}` and gives the outbound Worker the parameters `egress` and `app` (the slug).
The app receives the request headers without `x-salix-*`, `x-comma-*` (except version and viewer), `cf-*`, `host`, `authorization` and `cookie`.
The app request URL is `https://app.invalid/<path>?<query>`.

| Result | Response |
| --- | --- |
| App response | Passes through unchanged. |
| The script throws, or exceeds a limit | 502 `{"error": "app_error", "message"}` |
| The script does not exist, or is not a Version script | 404 `{"error": "not_found"}` |
| Body over `MINIAPP_DISPATCH_MAX_BODY_BYTES` (default 1 MiB) | 413 `{"error": "body_too_large"}` |
| Bad method or egress header | 400 `{"error": "invalid"}` |

## Outbound Worker

Every `fetch` from an app script goes through the outbound Worker. A request leaves only when all of these are true:

- The URL is `https://` on the default port, without user name or password.
- The host is in the `egress` list of the Version.
- The host is not an IP literal and has at least one dot.
- The host is not a Comma host (`comma.surf`, `afk.surf` and their subdomains), a local name (`localhost`, `.local`, `.internal` and similar), or a suffix in `MINIAPP_BLOCKED_HOSTS` (comma-separated).

A refused request returns 403 `{"error": "egress_blocked", "message"}` to the app.
Redirects return to the app (`redirect: "manual"`). The app must fetch the new location, and that fetch is checked again.
Workers cannot open connections to private address ranges, so a public name that resolves to a private address does not reach a private network.

Rate limit: at most 600 outbound requests per app in 60 seconds, counted by the Cloudflare Rate Limiting binding `EGRESS_LIMITER`.
The binding counts per Cloudflare location, so the global bound is approximate.
Each app request can also make at most 50 subrequests. Over the limit, the app receives 429 `{"error": "rate_limited"}`.

## App storage (`env.STORAGE`)

The built module (`npm run build:storage` writes it into the Comma server's `priv/mini_apps/`) is one ES module. It exports the Durable Object class `AppStorage` (SQLite storage) and a default `fetch` handler that returns 404.
Build it with `npm run build:storage` and commit the result. CI fails when the file is not the build of `src/app-storage.ts`.

The Comma server uploads it as script `app-<slug>-data` with main module `app-storage.js` and, on the first upload, the migration `new_sqlite_classes: ["AppStorage"]`.
Each Version script binds `STORAGE` to `{type: "durable_object_namespace", class_name: "AppStorage", script_name: "app-<slug>-data"}`.
All Versions of an app use the same namespace, so data stays after a deploy.

An app script gets a storage object by name and sends it requests:

```ts
const store = env.STORAGE.get(env.STORAGE.idFromName("main"));
await store.fetch("https://storage/kv/habits/1", { method: "PUT", body: JSON.stringify({ done: true }) });
const res = await store.fetch("https://storage/kv/habits/1"); // {key, value}
```

| Request | Body | Result |
| --- | --- | --- |
| `GET /kv/<key>` | | `{key, value}`, or 404 `not_found` |
| `PUT /kv/<key>` | JSON value, at most 1 MiB | `{key}` |
| `DELETE /kv/<key>` | | `{deleted: boolean}` |
| `GET /kv?prefix=&after=&limit=` | | `{items: [{key, value}], has_more}`; `limit` 1 to 1000, default 100 |
| `POST /sql` | `{query, params?}`, at most 100 KiB | `{rows, truncated, rows_read, rows_written}` |

- Keys match `^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,255}$`. Encode a key with `encodeURIComponent` when it has other characters in a URL.
- SQL `params` has at most 100 values: strings, finite numbers, booleans (stored as 0 or 1) or `null`.
- A SQL request returns at most 1000 rows. `truncated` is `true` when more rows matched.
- Errors are `{"error": "<code>", "message"}` with status 400, 404, 405 or 413.

## Development

```sh
npm ci
npm test
npm run typecheck
npm run build:storage
```

Tests do not use the network. They call the Worker handlers with fake bindings.

## Deployment

`.github/workflows/miniapp-dispatch.yml` deploys from `main` (staging) and `prod` (stable), or by `workflow_dispatch` from those branches.
It runs `wrangler deploy` for the outbound Worker, then for the dispatch Worker with `MINIAPP_DISPATCH_SECRET` from `--secrets-file`.

One-time Cloudflare setup per environment, before the first deploy:

1. Create the dispatch namespace: `npx wrangler dispatch-namespace create comma-miniapps-<env>`.
2. Make sure that the API token can edit Workers, Workers for Platforms and the custom domain zone `afk.surf`.

GitHub environment `staging` and `prod`:

- Secrets: `CLOUDFLARE_API_TOKEN`, `MINIAPP_DISPATCH_SECRET`.
- Variable or secret: `CLOUDFLARE_ACCOUNT_ID`.

The Comma server config `mini_apps.dispatch_base_url` is `https://miniapp-dispatch-staging.afk.surf` or `https://miniapp-dispatch-prod.afk.surf`.
`mini_apps.dispatch_secret` has the same value as `MINIAPP_DISPATCH_SECRET`.
`mini_apps.dispatch_namespace` is `comma-miniapps-<env>`.
