# Comma systems deployment guide

Cluster updates follow the [rollout policy](../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).
Temporary service failures are acceptable during rolling updates. Full recovery must meet the documented convergence budgets.

How to run the Comma systems umbrella in production. The platform ships as a
single `mix release comma` in **one Docker image** (built from
[`Dockerfile`](Dockerfile)); each pod runs the subsystems it selects. Sections
below `## Salix subsystem` document the Salix runtime specifically. Its
Willow-to-Salix migration runbook is:
[`../docs/product-features.md`](../docs/product-features.md).

## Self-hosted Compose

The root `compose.yaml` starts Comma Web, Comma Admin, Comma Product, Salix, PostgreSQL, Redis, MinIO, ClickHouse, and a local SMTP inbox.
It builds the server's `runtime` target. It does not require the private meeting runtime source or the hosted release infrastructure.
MinIO and its bucket client build from fixed upstream GitHub releases in `selfhost/Storage.Dockerfile`.
Their versions and the existing `objects` volume layout remain unchanged.
The first build downloads public toolchains and dependencies, including Lean, Elixir, Go, Node, and spinfoam.
Allow enough disk space for build layers. Minimum memory and disk requirements have not been benchmarked.

### First start

1. Install Docker Engine and Compose v2.24 or later.
2. Copy `.env.example` to `.env` at the repository root.
3. Set your model endpoint, protocol, model name, and key in `.env`.
4. Run `docker compose up -d --build`.
5. Open `http://localhost:8080`.
6. Request an email login code.
7. Read the code at `http://localhost:8025` and complete login.

Without an instance model key, configure your own provider account and model in Settings before chat.
Provider calls use your account and can incur provider charges.
Each new self-hosted Workspace receives the existing unlimited-metered entitlement.
Comma records usage without requiring Stripe or Comma credit purchases. Authorization and interaction budgets still apply.

The `configure` service creates secrets once in the `config` volume.
Later starts preserve those secrets and regenerate runtime configuration from `.env`.
Do not delete that volume or replace its subscription encryption key.
No developer user, bearer, mock model, or staging credential is installed.
The local Mailpit inbox is for loopback use only. Anyone who can read it can use its login codes.

### Verify an isolated installation

The optional test override supplies a deterministic local model and an explicit test owner.
Use a separate Compose project and free local ports. Never load this override into a real instance.

```sh
docker compose -p comma-smoke -f compose.yaml -f selfhost/compose.test.yaml up -d --build
pnpm --dir clients exec playwright test --config packages/app/e2e/selfhost.playwright.config.ts
docker compose -p comma-smoke -f compose.yaml -f selfhost/compose.test.yaml down
python3 -m unittest discover -s selfhost
```

The browser test covers email login, a model reply, saved chat history, a Worker task, Admin login, and source access.
The mock consumes no paid model credentials. Production Compose never loads it.

### Public access

Use your existing HTTPS reverse proxy for a public installation.
Web, Admin, and the Comma Product API must use different origins within the same schemeful site:
HTTPS on one registrable domain. For example:

```dotenv
COMMA_PUBLIC_URL=https://app.example.com
COMMA_ADMIN_URL=https://admin.example.com
COMMA_API_URL=https://api.example.com
COMMA_SALIX_URL=https://salix.example.com
```

Proxy Web to port 8080, Admin to port 8082, the Comma Product API to port 8081, and Salix to port 4000.
Separate browser and API origins preserve the existing explicit-Origin cookie contract.
The session Cookie uses `SameSite=Lax`; credentialed browser fetches require Web/Admin and Product API to be same-site.
Cross-site combinations such as `app.example.com`, `api.example.net`, and `admin.example.org` are not supported.
CORS configuration does not remove this Cookie restriction.
The configuration generator checks origin syntax and HTTPS, but does not validate the public suffix list or this same-site relationship.
For loopback access, keep the same hostname in all browser/API URLs; do not mix `localhost` with `127.0.0.1`.

The Admin client is available locally at `http://localhost:8082`.
The configured owner email receives Admin access. The hosted `comma.surf` domain rule does not apply to self-hosted instances.
Existing explicit Admin allow/deny decisions keep precedence.

Set `COMMA_OWNER_EMAIL` to create your first account. Public registration is off unless `COMMA_ALLOW_SIGNUP=true`.
Existing accounts can still sign in. Local loopback installations allow registration for evaluation.

Keep the default loopback port bindings when the proxy runs on the same host.
Preserve Host, Origin, cookies, WebSocket upgrades, and streaming responses.
Disable proxy buffering for event streams. Do not expose database or BEAM ports.
Set `COMMA_SMTP_HOST`, port, sender, username, and password for your mail provider.
Use `COMMA_SMTP_TLS=always` for STARTTLS, or `COMMA_SMTP_SSL=true` for implicit TLS.
TLS verifies the relay certificate and hostname. Plaintext SMTP is an explicit option for a trusted internal relay.
The configuration generator refuses remote HTTP origins and a public deployment with the local Mailpit relay.

Recreate the services after configuration changes:

```sh
docker compose down
docker compose up -d --build
```

`down` preserves named volumes. Never add `-v` unless you intend to delete the instance.
The Web build reads `COMMA_API_URL`. Rebuild it after a domain change. No source edit is required.
The served `/source.tar.gz` contains the corresponding source for that Web image build.
Keep that download available when you serve modified versions.

### Features and external accounts

Internal agents, tasks, object storage, search, and subscription-account storage run in this stack.
Supply provider credentials for real model calls and any enabled external integrations.
To run commands on your own machine, enroll its Connector through the existing device setup.
Cloud VMs are off by default for new self-hosted Workspaces. Existing and explicit selections are preserved.
New Group cloud compute requires Cloudflare configuration.
Meetings and Agent VMM host provisioning require their separately distributed runtimes.
The default stack does not build the private `meetnative` source or bundle an ARM-only VMM image.
This separation does not convert those external runtimes into open-source components of Comma.

### Upgrade and recovery

1. Stop the stack with `docker compose down`.
2. Back up all five named volumes: config, postgres, objects, clickhouse, and redis.
3. Keep the backup and its source revision together.
4. Check out the next release.
5. Run `docker compose up -d --build`.
6. Check `docker compose ps` and `docker compose logs migrate comma`.
7. Verify login, saved conversations, a model reply, and your device connections.

The initializer is offline and idempotent. Do not run it against a serving hosted cluster.
Existing product facts are preserved. A nonempty unfinished import requires its original migration handoff.
After a schema change, recover forward or restore the entire stopped-volume backup with its matching source revision.
Do not point an older image at a newer schema without a documented downgrade path.
Test recovery in an isolated Compose project before relying on a backup.

## Subsystem selection

`COMMA_SUBSYSTEMS` (comma-separated subsystem names; unset = every subsystem in
the build) chooses what a pod runs — one image, per-pod role:

```sh
COMMA_SUBSYSTEMS=salix bin/comma start
```

Unselected subsystems' apps stay loaded-but-not-started, and their runtime
config and prod requirement checks are skipped — a node needs only its own
subsystems' configuration. An unknown name fails fast at boot. Platform-wide
BEAM concerns (`RELEASE_COOKIE`, `RELEASE_NODE`, EPMD + distribution ports)
apply to every node regardless of subsystem.

## Salix subsystem

### Topology in one paragraph

Every node running Salix runs the **same `salix_*` apps** — no build-time roles:
any node serves HTTP, accepts deliveries, and runs agent Servers; cluster
singletons (recovery, GC, timers, schedules, metering/analytics mirror) are
**lease-gated on S3 CAS objects**. Aggregate state and content use object storage. Control and
coordination data use PostgreSQL through `salix.database.url`; production
startup requires that configuration. Redis supports distributed authentication
and rate limiting. Nodes discover each other via libcluster;
losing any node loses at most the un-acked tail of in-flight rounds (recovered
by claim + repair, at worst within the 60s lease TTL).

### Object storage requirements

| Requirement                      | Why                                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Conditional object create/update | The entire commit protocol (head CAS, create-once receipts/run objects). AWS S3 and MinIO use `If-None-Match: *` / `If-Match: <etag>`; GCS XML API uses object-generation preconditions when `storage.atomic_operations` is `"gcp"`.                                                                                                                                                                                       |
| Conditional `DELETE`             | Marker-family deletes (participant wakeup markers, lease/run records). AWS S3: `native` (`If-Match`). MinIO (as of 2025-09): `emulate` (HEAD-compare-then-delete; non-atomic — the TOCTOU exposure per marker family is specified in the ETag-semantics SSOT in `docs/storage-search.md`; the staged-delivery queue-marker family retired with A2 §3.4). GCS mode uses generation preconditions for native atomic deletes. |
| Strong read-after-write          | The selected backend must provide this for GET-and-check ambiguity recovery. S3 API compatibility alone does not prove it.                                                                                                                                                                                                                                                                                                 |
| Per-prefix request-rate headroom | Keys are sharded by design (per-node `ctl/leases/`, per-agent and per-session prefixes); a busy round is approximately 12 PUT-class requests (the A2 §3.4 retirement removed the per-delivery inbox/marker/touch PUTs).                                                                                                                                                                                                    |

IAM must cover ordinary objects plus cleanup of multipart uploads whose uploader
dies before it checkpoints the upload id. Grant only the corresponding bucket
and object resources:

| Backend                            | Bucket permissions                                      | Object permissions                                                                                                                             |
| ---------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| AWS S3 / MinIO policy actions      | `s3:ListBucket`, `s3:ListBucketMultipartUploads`        | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`                                                                   |
| GCS IAM permissions (XML API mode) | `storage.objects.list`, `storage.multipartUploads.list` | `storage.objects.get`, `storage.objects.create`, `storage.objects.delete`, `storage.multipartUploads.create`, `storage.multipartUploads.abort` |

AWS documents the list and abort actions in its
[multipart upload permissions table](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html#mpuAndPermissions).
GCS lists the matching permissions in its
[Cloud Storage IAM permission reference](https://cloud.google.com/storage/docs/access-control/iam-permissions#multipart-upload).
Do not deploy the prepared-blob cleanup worker with only the legacy object CRUD
policy: a `403` while listing or aborting multipart sessions deliberately keeps
the durable cleanup intent and upload for retry, so missing permission becomes a
retention leak instead of an unsafe delete.

When changing storage IAM, backend, or multipart cleanup, test a disposable
prefix with the target workload credential. Stop one multipart write before its
upload ID checkpoint, then run one cleanup sweep. The sweep must abort that
upload and clear its intent. A `403` blocks the affected change until IAM is
corrected. Ordinary releases do not repeat this test.

### Configuration: config.json

Like willow, Salix reads one structured **`config.json`**:
`SALIX_CONFIG_PATH` when explicitly set, else `/etc/salix/config.json`, else
`config.json` when present. See
[`config/config.example.json`](config/config.example.json) for all sections.
Runtime settings are not resolved from per-setting environment-variable
fallbacks. In k8s the file is mounted from a content-addressed `salix-config-*`
candidate Secret, built by the release CLI from `SALIX_CONFIG_JSON` plus Secret
Manager values. Serving references change only during the controller's apply
stage.

Required in prod:

| Config path                                              | Meaning                                                                          |
| -------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `storage.endpoint`                                       | e.g. `https://s3.us-east-1.amazonaws.com` or `http://minio:9000`                 |
| `storage.bucket`                                         | the bucket                                                                       |
| `storage.access_key_id` / `storage.secret_access_key`    | credentials                                                                      |
| `storage.timeouts.{fast_recv_ms,bulk_recv_ms,budget_ms}` | optional S3-adapter latency knobs; see the table below                           |
| `web.api_token`                                          | bearer token for the admin HTTP API                                              |
| `salix_dashboard.secret_key_base`                        | Phoenix session signing secret for `/dash`                                       |
| `salix.database.url`                                     | Salix-owned PostgreSQL connection; required when `salix` is enabled              |
| `billing.database.url`                                   | Billing-owned PostgreSQL connection; required by every billing-capable subsystem |
| `comma.database.url`                                       | Comma-owned PostgreSQL connection; required when `comma_product` is enabled          |
| `bridge_for_teams.database.url`                          | BFT-owned PostgreSQL connection; required when `bridge_for_teams` is enabled     |

Optional Comma-to-Synchronicity provisioning uses one fail-closed section:

| Config path                             | Meaning                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `comma.synchronicity.base_url`            | Synchronicity control-plane HTTPS origin; literal loopback HTTP is allowed for local development |
| `comma.synchronicity.provisioning_secret` | Shared bearer secret, at least 32 bytes; must match Synchronicity's `CP_COMMA_PROVISIONING_SECRET` |

Omit the entire `comma.synchronicity` object to disable provisioning. If the
object is present, both fields are required and unknown fields, malformed
origins, or short secrets refuse boot. There are no `SYNC_*` environment
fallbacks; release configuration remains single-source through `config.json`.
The Synchronicity control plane must independently set
`CP_COMMA_PROVISIONING_ENABLED=true` and the same
`CP_COMMA_PROVISIONING_SECRET`, plus `CP_COMMA_OIDC_PROVIDER_ID` to the shared Comma
OIDC provider, before Comma begins convergence. Register that provider's
confidential client in Comma Admin with Synchronicity's exact
`/auth/callback/oidc` redirect URI; copy its one-time secret into the
Synchronicity OIDC provider configuration.

The production OTP release does not ship Mix. Provision one existing Workspace
or backfill a bounded batch through the running Comma node instead:

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity("wsp_...")'

kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity(all_missing: true, limit: 100)'
```

Resolve and verify `$COMMA_KUBE_CONTEXT` explicitly before either command, and
select a ready `comma` Pod if `comma-0` is unavailable. The batch processes
Workspace ids in ascending order, persists every success immediately, and
raises after a partial failure so the command exits nonzero. Re-running it skips
rows that now have both Synchronicity ids. The limit defaults to 100 and must be
between 1 and 1000; there is deliberately no argument-free bulk mode.

To refresh flags for all non-deleted Workspaces, including those with complete
mappings, use the explicit refresh mode. This forces file browsing and cloud
hosting on through the Synchronicity provisioning endpoint, including settings
that an administrator previously disabled. Release the corresponding
Synchronicity behavior before you run this refresh.

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity(refresh_all: true, limit: 100)'
```

For the next page, add `after_id: "wsp_..."` with the returned
`last_workspace_id`. Continue until `processed` is zero. Retry failed Workspace
ids before advancing the cursor. A failed page does not undo successful rows.
The cursor is an exclusive Workspace-id bound, not a saved job or snapshot.
Use `all_missing` or `refresh_all`, not both. The existing `all_missing` mode
still skips complete mappings.

Convergence also mints one `member` org key per Workspace through the same
secret and stores it as the Workspace group's Drive binding in Salix, so the
agent can read and write the Workspace's Drive at `/drive`
(`docs/tools-integrations.md`). The binding appears on the group page
of the Salix dashboard (Drive tab) marked `comma`. To replace one Workspace's
key on demand, for example after a suspected leak:

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Synchronicity.rotate_agent_key("wsp_...")'
```

`{:ok, :minted}` means the new key is stored and the old one is revoked.
`{:error, {:retryable, {:revoke_pending, %{key_ids: [...], reason: ...}}}}`
means the new key is stored but the control plane did not confirm the
revocation: treat the listed keys as still valid, and run the command again
(or wait for the next convergence, which retries it) until it answers
`{:ok, ...}`. The pending ids also show on the group's Drive tab. To end it
by hand, revoke the listed key in the Synchronicity dashboard; the next
retry reads `not-found` and clears it. A binding an operator saved or
disabled on the group's Drive tab is the operator's: convergence and
rotation answer `{:ok, :manual}` and change nothing, and that includes the
pending revocations. After such a takeover, revoke the keys the Drive tab
still lists in the Synchronicity dashboard yourself; Comma no longer retries
them.

The control plane must carry the `api-keys` internal routes
(`AFK-surf/synchronicity#146`) before Comma with this behaviour converges a
Workspace; an older control plane answers 404 and the Workspace fails
convergence as `synchronicity_invalid`. Workspaces provisioned before this
behaviour get a binding on their next convergence or through the
`refresh_all` loop above.

### Drive for other deployments (Salix dashboard)

The Drive integration itself is Salix's, and a deployment without Comma
Workspace provisioning (BridgeForTeams) configures it by hand in the Salix
dashboard: the control-plane origin under **Drive** (`/dash/drive`, as the
platform default or per tenant), and per group, on the group page's **Drive**
tab, the Synchronicity org slug, network, space and an org API key of
`member` role minted in the Synchronicity dashboard (Settings → API keys).
The **Check** button on that tab asks the control plane whether the binding
can read and write. The key is stored in `drive_bindings` like the other
provider credentials in the Salix store.

### S3 adapter timeouts (`storage.timeouts`)

All three fields are optional positive integers in milliseconds (at most
86400000). Any other shape — a non-object section, an unknown field, a
non-integer, zero/negative, or an over-ceiling value — refuses the load
rather than silently reverting to defaults, so a mistyped incident override
cannot pass unnoticed.

| Field          | Default | What it bounds                                                                                                                                            | When to change it                                                                                                  |
| -------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `fast_recv_ms` | 10000   | Per-attempt receive timeout for small operations: GET/HEAD/DELETE/LIST and PUTs under 8MiB (the store's dominant shape)                                   | Raise if a healthy-but-slow backend trips small reads; lower to shed a stalling connection sooner                  |
| `bulk_recv_ms` | 30000   | Per-attempt receive timeout where transfer time is real: PUTs at/over 8MiB, multipart part/complete, streamed responses                                   | Raise for large objects over slow links; lowering mainly affects big uploads                                       |
| `budget_ms`    | 20000   | The whole-call budget across all transient retries; each attempt uses `min(tier, remaining budget)` and no new attempt or backoff starts once it is spent | Raise if legitimate slow calls are being cut off; lower to fail faster during a backend stall (the incident lever) |

Scope: the budget bounds the **remote I/O stages** — connection-pool
checkout, connect, request-body send, response receive. Local CPU work on
the payload (traversing/normalizing a caller's `iodata`, SigV4 signing) is
deterministic work proportional to the caller's own payload and is
deliberately outside the promised bound; callers that need an absolute limit
from their own call site impose it there. Streamed responses (`stream/2`)
are the other deliberate exception: a stream is bounded per read by
`bulk_recv_ms`, so one that keeps receiving chunks may run past `budget_ms`
by design.
Watch `salix_store_inflight_oldest_age_seconds` against `budget_ms`: a
sustained excess with collapsing `salix_operations_total` rates is the
store-stall signature.

Production also requires `REDIS_URL` (or the legacy environment alias
`COMMA_REDIS_URL`) for distributed authentication and global rate limiting.
There is no in-memory fallback when Redis is unavailable. Salix, Comma, Billing, and BFT
have separate Repo/schema ownership even when an environment deliberately maps
their URLs to one Cloud SQL database; do not infer or copy one URL at runtime.

LLM provider configuration is **per agent template only** (willow parity —
`provider_config` with `protocol` / `base_url` / `api_key` or `api_key_env`,
plus the template's `model` / `max_tokens`): there is no cluster-wide LLM
fallback. `api_key_env` lets a template name an OS environment variable so
keys stay out of S3.

Common config paths:

| Config path                    | Default           | Meaning                                                                                                                                                                                         |
| ------------------------------ | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `storage.region`               | `us-east-1`       | SigV4 region                                                                                                                                                                                    |
| `storage.atomic_operations`    | `s3`              | `s3` for ETag conditionals (AWS/MinIO), `gcp` for GCS object-generation preconditions                                                                                                           |
| `storage.conditional_delete`   | `native`          | `native` (AWS) / `emulate` (MinIO)                                                                                                                                                              |
| `web.port`                     | `4000`            | API + SSE                                                                                                                                                                                       |
| `web.sites_domain`             | `salix.localhost` | wildcard domain for agent-hosted websites (`{site}-{b32-agent-id}.{domain}` must resolve to the API listener; DNS `*.{domain}` + LB pass-through). Unset/empty disables host-based site serving |
| `transfer.port`                | `4400`            | inter-node byte streaming (must be node-to-node reachable)                                                                                                                                      |
| `transfer.advertise_host`      | `127.0.0.1`       | address peers use for transfer URLs on non-k8s installs                                                                                                                                         |
| `transfer.advertise_port`      | `transfer.port`   | externally reachable port carried in transfer URLs when port forwarding differs from the listener                                                                                               |
| `cluster.strategy`             | unset             | `kubernetes_dns` \| `gossip` \| unset (single node)                                                                                                                                             |
| `cluster.k8s_headless_service` | —                 | required with `kubernetes_dns`                                                                                                                                                                  |
| `clickhouse.url`               | unset             | enables the analytics ClickHouse sink                                                                                                                                                           |
| `log.file`                     | unset (disabled)  | verbose JSONL diagnostic log path (`--log-file` can still override it for ad hoc local runs)                                                                                                    |

Platform environment variables still exist only for values that cannot be shared
inside one JSON file:

| Var                    | Meaning                                                           |
| ---------------------- | ----------------------------------------------------------------- |
| `COMMA_SUBSYSTEMS`       | per-pod subsystem selection                                       |
| `SALIX_ADVERTISE_HOST` | k8s pod IP override for transfer URLs                             |
| `RELEASE_COOKIE`       | BEAM cookie; set explicitly and keep identical across the cluster |
| `RELEASE_NODE`         | use `salix@<pod-ip>` with longnames in k8s                        |

GCS note: when `storage.atomic_operations` is `"gcp"`, Salix signs requests with
the GCS XML API V4 namespace (`GOOG4-HMAC-SHA256`, `x-goog-*` headers) and uses
object generations as the CAS token. Do not mix this mode with `x-amz-*`
extension headers.

### Ports

| Port      | Scope              | Purpose                                                                                                 |
| --------- | ------------------ | ------------------------------------------------------------------------------------------------------- |
| 4000      | ingress + internal | HTTP API, SSE                                                                                           |
| 4400      | node↔node only     | transfer server (one-time-token byte streams)                                                           |
| 4369      | node↔node only     | EPMD                                                                                                    |
| 9100–9110 | node↔node only     | BEAM distribution (pin with `ERL_AFLAGS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110"`) |

Never expose 4369/9100-9110/4400 publicly; distribution is protected only by
the cookie.

### Kubernetes sketch

StatefulSet or Deployment (durable state uses PostgreSQL and object storage), a
**headless service** for libcluster DNS, plus a normal service for ingress:

```yaml
env:
  - name: COMMA_SUBSYSTEMS
    value: salix # subsystems this pod runs (unset = all)
  - name: SALIX_ADVERTISE_HOST
    valueFrom: { fieldRef: { fieldPath: status.podIP } }
  - name: RELEASE_NODE
    value: salix@$(POD_IP) # with RELEASE_DISTRIBUTION=name
volumeMounts:
  - name: salix-config
    mountPath: /etc/salix
    readOnly: true
lifecycle:
  preStop:
    exec:
      command:
        ["/bin/sh", "-c", "bin/comma rpc 'Comma.PodLifecycle.pre_stop([])' || true"]
terminationGracePeriodSeconds: 90
startupProbe:
  httpGet: { path: /live, port: 4000 }
livenessProbe:
  httpGet: { path: /live, port: 4000 }
readinessProbe:
  httpGet: { path: /ready, port: 4000 }
```

**Lifecycle and drain:** `Comma.PodLifecycle` owns the Pod-local contract for all
enabled surfaces. `/live` proves only that the serving BEAM is alive. `/ready`
is side-effect free and checks local drain state, the surface's started OTP
applications, and (for Comma Product) the database schema contract. Provider,
Redis, S3, and remote-node probes remain operational telemetry and do not make
every Pod flap out of readiness during a transient dependency failure.

The preStop hook first withdraws readiness and rejects new non-health requests,
then pauses this Pod's Comma Oban queues, waits a bounded grace period for running
jobs, and finally invokes the Salix actor drain. Salix-only and product-only
Pods use the same entry point; disabled stages are bounded no-ops. The Salix
stage stops local agent/session processes at a boundary, releases agent leases
via head CAS, hands work to the ring owner, and stops only this pod's local
Cloudflare attachments. A normal rolling update does not
destroy all VMs globally; recovery/revive reconnects them from durable records.
The hosted chart runs Cloud SQL Proxy as an `initContainers` sidecar with
`restartPolicy: Always`. Kubernetes stops it after the application container exits.
The proxy remains running during preStop and application shutdown.
The Pod termination budget includes both stages.
Keep `terminationGracePeriodSeconds` long enough for readiness propagation,
Oban shutdown grace, agent lease release, and VM channel cleanup. If Kubernetes
forcibly kills a Pod, durable Oban operations and Salix recovery resume work on
another eligible Pod.

**Scaling:** adding nodes rebalances libring placement. S3 head CAS fences durable commits. 100K mostly-paused agents
cost ~zero compute (passivated agents are pure S3 objects) and ~$50–100/mo of
background sweeps at the documented storage/request assumptions.

### spinfoam (Background Loops and scripts)

Salix pods run one [spinfoam](https://github.com/AFK-surf/spinfoam) child
process per node for Agent background Loops and for one-shot `script.run`
programs (`docs/salix/tasks-background-execution.md`, "Background loops" and
"Scripts").
The image downloads the prebuilt release pinned in
`systems/native/spinfoam/SPINFOAM_VERSION` and verifies it against the pinned
`SHA256SUMS`. Loops are agent-authored C compiled
by spinfoam's embedded compiler: TinyCC compiled to eBPF, run inside spinfoam's
own VM. Nothing is packaged as a template.

At runtime nothing beyond the binary is needed: no host toolchain, no
sandbox, no user namespaces, no privilege. The Host starts spinfoam with
`--enable-builds`. Nothing is compiled at image build time either: the fetch
stage needs only network access to github.com. When enabling or changing the
embedded compiler, confirm on staging with
`bin/comma rpc 'IO.inspect(SalixAgent.Loops.Host.status())'`
(`compiler.available: true`, `embedded: true`) before rolling out.

Capacity: spinfoam runs in the Salix container's cgroup, so its memory counts
toward `SessionResidency` pressure. `:salix_agent, :spinfoam_max_objects`
(default 2000) bounds resident objects per node, `:salix_agent,
:script_max_objects` (default 64) the script objects among them; each active
Loop is planned below 1 MB; each build runs the compiler guest with a fresh
8 MiB arena and a 15-second deadline. A small program compiles in about
0.2 s; spinfoam v0.1.1 keeps no build cache and neither it nor Salix
serializes concurrent builds, so every `loop.build` and `script.run`
compiles afresh. All objects share one execution thread: a busy script or
build slows the node's Loops.

### Single-VM deployment

Use the [self-hosted Compose entry point](#self-hosted-compose) for the full Comma product.
The Salix subsystem alone does not serve Comma login or the Web client.

### Operations

- **Health**: `GET /live` is liveness; `GET /ready` is local readiness.
  `/health` remains a readiness alias for compatibility and must not be used as
  a liveness probe. The storage kernel is `rest_for_one` at the root, so a dead
  kernel takes the node down by design (fail-stop).
- **Logs/metrics**: standard Logger to stdout. Lease losses log as
  warnings; `fenced; terminating` lines are _normal_ during steals/drains.
- **Cloud VM ops**:
  The three list endpoints below return `{data, next_cursor}`.
  Set `limit` from 1 to 100 (default 50), and pass `next_cursor` as the next request's `cursor`.
  Read until `next_cursor` is null before drawing a full-scope conclusion. An empty `data` page can have a next cursor.
  - `GET /v1/admin/vm/worker-release` shows the Salix-controlled desired
    Worker version. `GET /v1/admin/vm/worker-release/outdated` lists
    Cloudflare VMs whose `current_worker_version_id` has not converged.
  - `GET /v1/admin/vm/ops/stuck` lists Cloudflare VM records in
    `creating`, `reviving`, `archiving`, `waking`, or `failed`, including
    `ops_age_ms` and `last_error` when present.
  - `GET /v1/admin/vm/ops/keepalive-leaks` lists Cloudflare records that still
    imply provider keepAlive but no longer have a live Salix attachment. Use it
    after teardown, idle archive rollout, and node drains; the expected steady
    state after archive is an `archived` record that does not appear here.
  - Worker/gateway logs emit `sandbox_ensure`, `sandbox_status`,
    `sandbox_connect`, `sandbox_keepalive`, `sandbox_destroy`,
    `sandbox_checkpoint`, and `sandbox_restore` with
    `worker_version_id`, `worker_version_tag`, `gateway_build_id`, and
    `connector_image_version`. Salix CloudVM records also persist the Worker
    metadata under `provider_spec.cloudflare_worker`, so one VM call can be
    tied back to the Worker and connector image that served it.
  - Cloudflare attachments use the shared Connector protocol owner. Disconnect terminates that connection's pending requests and streams.
    Interrupted non-idempotent calls return `vm_reconnecting` and are not replayed automatically.
  - Connector archive and native checkpoint/restore failures are recorded in
    VM `last_error` and gateway operation logs. Connector archive is the
    durable recovery source; native checkpoint/snapshot is an optional
    provider-local acceleration layer.
- **Background singletons**: recovery (10s), GC, timers (1min buckets),
  schedules — all lease-gated; check `ctl/singletons/*.json` to see holders.
- **IM provider connects**: configure provider-specific connects per group.
  Inbound provider events enter the group router session through SalixIM.
- **Migration from Go willow**: follow
  [`docs/product-features.md`](../docs/product-features.md);
  export per agent with
  `willow-salix-export -db <agent.db>` (built from the willow repo), import
  with `SalixMigrate.Import.import_agent/3`, and verify the one-way routing flag
  through `SalixMigrate.Cutover.route/1`. A successful normal import writes
  `migrated: true`; `mark_migrated/1` is only for a separately staged record
  whose flag is still false. Roll out externally prepared records with
  `SalixMigrate.Cohort`.
- **Backups/DR**: preserve PostgreSQL, object storage, and persistent encryption keys together.
  Include ClickHouse and Redis according to their configured use. Bucket backups alone cannot restore the product.
  Verify restoration with the matching release before admitting users.

## CI

`.github/workflows/systems-ci.yml` gates every PR touching `systems/**` against
a real MinIO, a two-node fencing test, and a ClickHouse service.
`.github/workflows/systems-docker.yml` builds and publishes the image.


## Cloudflare Group VM archives

The Connector uses full archives before an idle stop and ordinary image replacement.
Fault recovery can use a critical checkpoint after persistent sealing and quiet confirmation.
Archives have no total entry count limit. The expanded content
limit is 16 GiB, and the compressed content limit is 4 GiB. The archive
excludes generated caches. It retains dependency installation trees, local changes,
Git metadata, settings, credentials, the Salix managed runtime, and other ignored files.
An Agent can use `env.dependency_installations` to
declare repository packages or manually installed tools. A declaration does not
exclude a directory by itself. The archive drops a declaration when its source
directory was deleted before packing. Restore preserves internal symbolic links
even when an older archive omitted their package or cache targets.
It still rejects links and extraction paths that escape the workspace.
After a restore from an older archive, supported omitted
packages install in the background. The Agent can read progress, stop the
installer, and use the normal shell to install packages itself. An installation
failure does not block VM commands.

Recovery scope omits Agent workspaces, managed dependency packages, and workspace sweep archives.
It retains runtime identity, native continuation, required credentials, and unknown files outside those paths.
Required native files inside an omitted tree remain in the checkpoint.
Active inputs and unacknowledged results must settle before export. Missing critical facts stop deletion.
The original Salix Session resumes with a notice to rebuild omitted files and dependencies.
Previous recovery generations remain held. Normal full archives keep their existing retention guarantee.
See [Gateway recovery boundaries](cloudflare/salix-vm-gateway/RELEASE.md#container-image-release) for exact repair conditions.

New Cloudflare archives use direct Connector transfer to R2 with short-lived
URLs signed by Salix. Set `cloud_vm_archives.r2` in the environment config with
the endpoint, bucket, access key ID, and secret access key. Old Connector
images export to Salix S3 until their image updates. Old Salix S3 generations
remain readable and are deleted after a later archive replaces them. Restore
uses a complete Salix S3 copy of the same generation if R2 cannot serve it.

After Comma Deployment publishes the mainline Comma release, its Gateway image job
runs automatically. Worker-only changes use a 0% candidate. A full Container
image replacement can destroy Group disks, so the job archives running Group
Containers and checks accepted work before replacing the image. See the
[Gateway release procedure](cloudflare/salix-vm-gateway/RELEASE.md) for the
release contract. A specific disk disposal or deployment-wide shutdown needs
its owner's approval.
