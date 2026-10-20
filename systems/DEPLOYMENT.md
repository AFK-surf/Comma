# Comma systems deployment guide

Cluster updates follow the [rollout policy](../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).
Temporary service failures are acceptable during rolling updates. Full recovery must meet the documented convergence budgets.

The platform ships as one `mix release comma` in one Docker image, built from [`Dockerfile`](Dockerfile).
Each pod runs the subsystems it selects.

## Self-hosted Compose

The root `compose.yaml` starts Comma Web, Comma Admin, Comma Product, Salix, PostgreSQL, Redis, MinIO, ClickHouse, and a local SMTP inbox.
It builds the server's `runtime` target. It does not need the private meeting runtime source or the hosted release infrastructure.
MinIO and its bucket client build from fixed upstream GitHub releases in `selfhost/Storage.Dockerfile`.
The first build downloads public toolchains and dependencies. Allow enough disk space for build layers.

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
Each new self-hosted Workspace gets the unlimited-metered entitlement.
Comma records usage without Stripe or Comma credit purchases. Authorization and interaction budgets still apply.

The `configure` service creates secrets once in the `config` volume.
Later starts keep those secrets and regenerate runtime configuration from `.env`.
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

### Public access

Use your existing HTTPS reverse proxy for a public installation.
Web, Admin, and the Comma Product API must use different origins on the same schemeful site: HTTPS on one registrable domain. For example:

```dotenv
COMMA_PUBLIC_URL=https://app.example.com
COMMA_ADMIN_URL=https://admin.example.com
COMMA_API_URL=https://api.example.com
COMMA_SALIX_URL=https://salix.example.com
```

Proxy Web to port 8080, Admin to port 8082, the Comma Product API to port 8081, and Salix to port 4000.
The session cookie uses `SameSite=Lax`. Credentialed browser fetches need Web, Admin, and the Product API on the same site.
Cross-site combinations such as `app.example.com`, `api.example.net`, and `admin.example.org` are not supported. CORS configuration does not remove this restriction.
The configuration generator checks origin syntax and HTTPS. It does not check the public suffix list or the same-site relationship.
For loopback access, use the same hostname in all browser and API URLs. Do not mix `localhost` with `127.0.0.1`.

The Admin client is at `http://localhost:8082`.
The configured owner email gets Admin access. The hosted `comma.surf` domain rule does not apply to self-hosted instances.
Explicit Admin allow and deny decisions keep precedence.

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

`down` keeps named volumes. Never add `-v` unless you intend to delete the instance.
The Web build reads `COMMA_API_URL`. Rebuild it after a domain change.
The served `/source.tar.gz` contains the source for that Web image build.
Keep that download available when you serve modified versions.

### Features and external accounts

Internal agents, tasks, object storage, search, and subscription-account storage run in this stack.
Supply provider credentials for real model calls and any enabled external integrations.
To run commands on your own machine, enroll its Connector through the device setup.
Cloud VMs are off by default for new self-hosted Workspaces. New Group cloud compute needs Cloudflare configuration.
Meetings and Agent VMM host provisioning need their separately distributed runtimes.
The default stack does not build the private `meetnative` source or bundle an ARM-only VMM image.
This separation does not make those external runtimes open-source components of Comma.

### Upgrade and recovery

1. Stop the stack with `docker compose down`.
2. Back up all five named volumes: config, postgres, objects, clickhouse, and redis.
3. Keep the backup and its source revision together.
4. Check out the next release.
5. Run `docker compose up -d --build`.
6. Check `docker compose ps` and `docker compose logs migrate comma`.
7. Verify login, saved conversations, a model reply, and your device connections.

The initializer is offline and idempotent. Do not run it against a serving hosted cluster.
A nonempty unfinished import needs its original migration handoff.
After a schema change, recover forward or restore the entire stopped-volume backup with its matching source revision.
Do not point an older image at a newer schema without a documented downgrade path.
Test recovery in an isolated Compose project before you rely on a backup.

## Subsystem selection

`COMMA_SUBSYSTEMS` is a comma-separated list of subsystem names. Unset means every subsystem in the build.

```sh
COMMA_SUBSYSTEMS=salix bin/comma start
```

A node needs only the configuration of its selected subsystems. An unknown name fails at boot.
`RELEASE_COOKIE`, `RELEASE_NODE`, EPMD, and distribution ports apply to every node.

## Salix subsystem

### Topology in one paragraph

Every Salix node runs the same `salix_*` apps. Any node serves HTTP, accepts deliveries, and runs agent Servers.
Cluster singletons (recovery, GC, timers, schedules, metering and analytics mirror) are lease-gated on S3 CAS objects.
Aggregate state and content use object storage. Control and coordination data use PostgreSQL through `salix.database.url`, which production requires.
Redis supports distributed authentication and rate limiting. Nodes find each other through libcluster.
A lost node loses at most the unacknowledged tail of in-flight rounds. Claim and repair recover it within the lease TTL.

### Object storage requirements

| Requirement                      | Why                                                                                                                                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Conditional object create/update | The commit protocol (head CAS, create-once receipts and run objects). AWS S3 and MinIO use `If-None-Match: *` / `If-Match: <etag>`. GCS uses object-generation preconditions in `gcp` mode. |
| Conditional `DELETE`             | Marker-family deletes (participant wakeup markers, lease and run records). AWS S3: `native` (`If-Match`). MinIO: `emulate` (HEAD, compare, then delete, not atomic). GCS: generation preconditions. |
| Strong read-after-write          | Needed for GET-and-check ambiguity recovery. S3 API compatibility alone does not prove it.                                                                                                  |
| Per-prefix request-rate headroom | Keys are sharded per node, per agent, and per session.                                                                                                                                      |

IAM must cover ordinary objects and cleanup of multipart uploads whose uploader dies before it checkpoints the upload id.
Grant only the matching bucket and object resources:

| Backend                            | Bucket permissions                                      | Object permissions                                                                                                                             |
| ---------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| AWS S3 / MinIO policy actions      | `s3:ListBucket`, `s3:ListBucketMultipartUploads`        | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`                                                                   |
| GCS IAM permissions (XML API mode) | `storage.objects.list`, `storage.multipartUploads.list` | `storage.objects.get`, `storage.objects.create`, `storage.objects.delete`, `storage.multipartUploads.create`, `storage.multipartUploads.abort` |

See the AWS [multipart upload permissions table](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html#mpuAndPermissions)
and the GCS [IAM permission reference](https://cloud.google.com/storage/docs/access-control/iam-permissions#multipart-upload).
Do not deploy the prepared-blob cleanup worker with only object CRUD permissions.
A `403` while it lists or aborts multipart sessions keeps the cleanup intent and upload for retry, so the data leaks instead of being deleted.

When you change storage IAM, backend, or multipart cleanup, test a disposable prefix with the target workload credential:

1. Stop one multipart write before its upload ID checkpoint.
2. Run one cleanup sweep.
3. Make sure the sweep aborts that upload and clears its intent.

A `403` blocks the change until IAM is correct. Ordinary releases do not repeat this test.

### Configuration: config.json

Salix reads one `config.json`: `SALIX_CONFIG_PATH` when set, else `/etc/salix/config.json`, else `config.json` when present.
See [`config/config.example.json`](config/config.example.json) for all sections.
Runtime settings have no per-setting environment-variable fallbacks.
In k8s the release CLI builds a content-addressed `salix-config-*` candidate Secret from `SALIX_CONFIG_JSON` and Secret Manager values, and mounts it as the file.
Serving references change only in the controller's apply stage.

Required in prod:

| Config path                                              | Meaning                                                                          |
| -------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `storage.endpoint`                                       | e.g. `https://s3.us-east-1.amazonaws.com` or `http://minio:9000`                 |
| `storage.bucket`                                         | the bucket                                                                       |
| `storage.access_key_id` / `storage.secret_access_key`    | credentials                                                                      |
| `storage.timeouts.{fast_recv_ms,bulk_recv_ms,budget_ms}` | optional S3 adapter timeouts, see [S3 adapter timeouts](#s3-adapter-timeouts-storagetimeouts) |
| `web.api_token`                                          | bearer token for the admin HTTP API                                              |
| `salix_dashboard.secret_key_base`                        | Phoenix session signing secret for `/dash`                                       |
| `salix.database.url`                                     | Salix-owned PostgreSQL connection, required when `salix` is enabled              |
| `billing.database.url`                                   | Billing-owned PostgreSQL connection, required by every billing-capable subsystem |
| `comma.database.url`                                     | Comma-owned PostgreSQL connection, required when `comma_product` is enabled      |
| `bridge_for_teams.database.url`                          | BFT-owned PostgreSQL connection, required when `bridge_for_teams` is enabled     |

Optional Comma-to-Synchronicity provisioning uses one fail-closed section:

| Config path                               | Meaning                                                                                              |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `comma.synchronicity.base_url`            | Synchronicity control-plane HTTPS origin. Literal loopback HTTP is allowed for local development.    |
| `comma.synchronicity.provisioning_secret` | Shared bearer secret, at least 32 bytes. It must match Synchronicity's `CP_COMMA_PROVISIONING_SECRET`. |

Omit the whole `comma.synchronicity` object to disable provisioning.
If the object is present, both fields are required. Unknown fields, malformed origins, or short secrets refuse boot.
There are no `SYNC_*` environment fallbacks.

Before Comma starts convergence, configure the Synchronicity control plane:

1. Set `CP_COMMA_PROVISIONING_ENABLED=true`.
2. Set the same `CP_COMMA_PROVISIONING_SECRET`.
3. Set `CP_COMMA_OIDC_PROVIDER_ID` to the shared Comma OIDC provider.
4. Register that provider's confidential client in Comma Admin with Synchronicity's exact `/auth/callback/oidc` redirect URI.
5. Copy its one-time secret into the Synchronicity OIDC provider configuration.

The production OTP release does not ship Mix. Provision one Workspace or a bounded batch through the running Comma node:

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity("wsp_...")'

kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity(all_missing: true, limit: 100)'
```

Resolve and verify `$COMMA_KUBE_CONTEXT` before either command. Select a ready `comma` Pod if `comma-0` is unavailable.
The batch processes Workspace ids in ascending order and saves each success at once.
After a partial failure it raises, so the command exits nonzero. A new run skips rows that have both Synchronicity ids.
There is no argument-free bulk mode.

To refresh flags for all non-deleted Workspaces, including complete mappings, use refresh mode.
It forces file browsing and cloud hosting on through the Synchronicity provisioning endpoint, including settings an administrator disabled.
Release the matching Synchronicity behavior before you run it.

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Release.provision_synchronicity(refresh_all: true, limit: 100)'
```

For the next page, add `after_id: "wsp_..."` with the returned `last_workspace_id`. Continue until `processed` is zero.
Retry failed Workspace ids before you advance the cursor. A failed page does not undo successful rows.
The cursor is an exclusive Workspace-id bound, not a saved job or snapshot.
Use `all_missing` or `refresh_all`, not both.

Convergence also mints one `member` org key per Workspace with the same secret.
It stores the key as the Workspace group's Drive binding in Salix, so the agent can read and write the Workspace Drive at `/drive` ([`docs/tools-integrations.md`](../docs/tools-integrations.md)).
The binding shows on the Salix dashboard group page (Drive tab), marked `comma`.
To replace one Workspace's key, for example after a suspected leak:

```sh
kubectl --context "$COMMA_KUBE_CONTEXT" -n comma exec pod/comma-0 -c comma -- \
  bin/comma rpc 'Comma.Synchronicity.rotate_agent_key("wsp_...")'
```

- `{:ok, :minted}`: the new key is stored and the old key is revoked.
- `{:error, {:retryable, {:revoke_pending, %{key_ids: [...], reason: ...}}}}`: the new key is stored, but the control plane did not confirm the revocation.
  Treat the listed keys as still valid. Run the command again, or wait for the next convergence, until it returns `{:ok, ...}`.
  The pending ids also show on the Drive tab. To end it by hand, revoke the listed key in the Synchronicity dashboard. The next retry reads `not-found` and clears it.
- `{:ok, :manual}`: an operator saved or disabled the binding on the Drive tab. Convergence and rotation change nothing, including pending revocations.
  Revoke the keys that the Drive tab still lists in the Synchronicity dashboard yourself. Comma no longer retries them.

The control plane must have the `api-keys` internal routes (`AFK-surf/synchronicity#146`).
An older control plane returns 404, and the Workspace fails convergence as `synchronicity_invalid`.

### Drive for other deployments (Salix dashboard)

A deployment without Comma Workspace provisioning (BridgeForTeams) configures Drive by hand in the Salix dashboard:

1. Under **Drive** (`/dash/drive`), set the control-plane origin as the platform default or per tenant.
2. On each group page's **Drive** tab, set the Synchronicity org slug, network, space, and a `member` org API key minted in the Synchronicity dashboard (Settings, API keys).
3. Click **Check** to ask the control plane whether the binding can read and write.

The key is stored in `drive_bindings` with the other provider credentials in the Salix store.

### S3 adapter timeouts (`storage.timeouts`)

All three fields are optional positive integers in milliseconds, with a ceiling in code.
Any other shape refuses the load, so a mistyped incident override cannot pass unnoticed.

| Field          | What it bounds                                                                                        | When to change it                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `fast_recv_ms` | Per-attempt receive timeout for GET, HEAD, DELETE, LIST, and small PUTs                               | Raise if a healthy but slow backend trips small reads. Lower to drop a stalled connection sooner.       |
| `bulk_recv_ms` | Per-attempt receive timeout for large PUTs, multipart part and complete, and streamed responses       | Raise for large objects over slow links.                                                                |
| `budget_ms`    | Whole-call budget across all transient retries. No new attempt or backoff starts after it is spent.   | Raise if legitimate slow calls are cut off. Lower to fail faster during a backend stall (the incident lever). |

The budget bounds remote I/O only. Local CPU work on the payload, such as SigV4 signing, is outside it.
A streamed response is bounded per read by `bulk_recv_ms`, so it can run past `budget_ms`.
Watch `salix_store_inflight_oldest_age_seconds` against `budget_ms`.
A sustained excess with falling `salix_operations_total` rates is the store-stall signature.

Production also requires `REDIS_URL` (or the legacy alias `COMMA_REDIS_URL`) for distributed authentication and global rate limiting.
There is no in-memory fallback when Redis is unavailable.
Salix, Comma, Billing, and BFT have separate Repo and schema ownership, even when an environment maps their URLs to one Cloud SQL database.
Do not infer or copy one URL from another at runtime.

LLM provider configuration is per agent template only: `provider_config` with `protocol`, `base_url`, and `api_key` or `api_key_env`, plus the template's `model` and `max_tokens`.
There is no cluster-wide LLM fallback. `api_key_env` names an OS environment variable, so keys stay out of S3.

Common config paths:

| Config path                    | Default           | Meaning                                                                                                                                                                         |
| ------------------------------ | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `storage.region`               | `us-east-1`       | SigV4 region                                                                                                                                                                    |
| `storage.atomic_operations`    | `s3`              | `s3` for ETag conditionals (AWS, MinIO), `gcp` for GCS object-generation preconditions                                                                                          |
| `storage.conditional_delete`   | `native`          | `native` (AWS) or `emulate` (MinIO)                                                                                                                                             |
| `web.port`                     | `4000`            | API and SSE                                                                                                                                                                     |
| `web.sites_domain`             | `salix.localhost` | wildcard domain for agent-hosted websites. `{site}-{b32-agent-id}.{domain}` must resolve to the API listener (DNS `*.{domain}` and LB pass-through). Empty disables site serving |
| `transfer.port`                | `4400`            | inter-node byte streaming. It must be reachable node to node                                                                                                                    |
| `transfer.advertise_host`      | `127.0.0.1`       | address peers use for transfer URLs on non-k8s installs                                                                                                                         |
| `transfer.advertise_port`      | `transfer.port`   | external port in transfer URLs when port forwarding differs from the listener                                                                                                   |
| `cluster.strategy`             | unset             | `kubernetes_dns`, `gossip`, or unset (single node)                                                                                                                              |
| `cluster.k8s_headless_service` | none              | required with `kubernetes_dns`                                                                                                                                                  |
| `clickhouse.url`               | unset             | enables the analytics ClickHouse sink                                                                                                                                           |
| `log.file`                     | unset (disabled)  | verbose JSONL diagnostic log path. `--log-file` overrides it for local runs                                                                                                     |

Environment variables exist only for values that one shared JSON file cannot hold:

| Var                    | Meaning                                                           |
| ---------------------- | ----------------------------------------------------------------- |
| `COMMA_SUBSYSTEMS`     | per-pod subsystem selection                                       |
| `SALIX_ADVERTISE_HOST` | k8s pod IP override for transfer URLs                             |
| `RELEASE_COOKIE`       | BEAM cookie. Set it explicitly and keep it identical across the cluster |
| `RELEASE_NODE`         | use `salix@<pod-ip>` with longnames in k8s                        |

In `gcp` mode, Salix signs requests with the GCS XML API V4 namespace (`GOOG4-HMAC-SHA256`, `x-goog-*` headers) and uses object generations as the CAS token.
Do not mix this mode with `x-amz-*` extension headers.

### Ports

| Port      | Scope              | Purpose                                                                                                 |
| --------- | ------------------ | ------------------------------------------------------------------------------------------------------- |
| 4000      | ingress + internal | HTTP API, SSE                                                                                           |
| 4400      | node to node only  | transfer server (one-time-token byte streams)                                                           |
| 4369      | node to node only  | EPMD                                                                                                    |
| 9100-9110 | node to node only  | BEAM distribution (pin with `ERL_AFLAGS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9110"`) |

Never expose 4369, 9100-9110, or 4400 publicly. Only the cookie protects distribution.

### Kubernetes sketch

Use a StatefulSet or Deployment (durable state is in PostgreSQL and object storage), a headless service for libcluster DNS, and a normal service for ingress:

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

**Lifecycle and drain:** `Comma.PodLifecycle` owns the Pod-local contract for all enabled surfaces.
`/live` proves only that the BEAM is alive. `/ready` has no side effects and checks local state only.
Provider, Redis, S3, and remote-node failures do not take Pods out of readiness.

The preStop hook withdraws readiness, drains this Pod's Comma Oban jobs, and then drains Salix actors.
The Salix stage releases agent leases, hands work to the ring owner, and stops only this Pod's Cloudflare attachments.
A rolling update does not destroy VMs. Recovery reconnects them from durable records.
The hosted chart runs Cloud SQL Proxy as an `initContainers` sidecar with `restartPolicy: Always`, so it keeps running through preStop and shutdown.
Keep `terminationGracePeriodSeconds` long enough for readiness propagation, Oban shutdown, lease release, and VM channel cleanup.
If Kubernetes kills a Pod, durable Oban jobs and Salix recovery resume the work on another Pod.

**Scaling:** new nodes rebalance libring placement. S3 head CAS fences durable commits.
Paused agents are S3 objects and use no compute.

### spinfoam (Background Loops and scripts)

Salix pods run one [spinfoam](https://github.com/AFK-surf/spinfoam) child process per node for Agent background Loops and one-shot `script.run` programs.
See [`docs/salix/tasks-background-execution.md`](../docs/salix/tasks-background-execution.md), "Background loops" and "Scripts".
The image downloads the release pinned in `systems/native/spinfoam/SPINFOAM_VERSION` and verifies it against the pinned `SHA256SUMS`.
spinfoam's embedded compiler builds the agent-written C to eBPF and runs it in spinfoam's own VM.

At runtime the binary needs no host toolchain, sandbox, user namespaces, or privilege. The image build needs network access to github.com only.
When you enable or change the embedded compiler, confirm on staging before rollout:

```sh
bin/comma rpc 'IO.inspect(SalixAgent.Loops.Host.status())'
```

The result must show `compiler.available: true` and `embedded: true`.

Capacity: spinfoam runs in the Salix container's cgroup, so its memory counts toward `SessionResidency` pressure.
`:salix_agent, :spinfoam_max_objects` bounds resident objects per node. `:salix_agent, :script_max_objects` bounds the script objects among them.
spinfoam keeps no build cache, so every `loop.build` and `script.run` compiles again.
All objects share one execution thread. A busy script or build slows the node's Loops.

### Single-VM deployment

Use the [self-hosted Compose entry point](#self-hosted-compose) for the full Comma product.
The Salix subsystem alone does not serve Comma login or the Web client.

### Operations

- **Health**: `GET /live` is liveness. `GET /ready` is local readiness.
  `/health` is a readiness alias. Do not use it as a liveness probe.
  A dead storage kernel stops the node by design (fail-stop).
- **Logs and metrics**: Logger writes to stdout. Lease losses log as warnings.
  `fenced; terminating` lines are normal during steals and drains.
- **Cloud VM ops**:
  The three list endpoints below return `{data, next_cursor}`.
  Set `limit` from 1 to 100 (default 50). Pass `next_cursor` as the next request's `cursor`.
  Read until `next_cursor` is null before you draw a full-scope conclusion. An empty `data` page can have a next cursor.
  - `GET /v1/admin/vm/worker-release` shows the desired Worker version that Salix controls.
    `GET /v1/admin/vm/worker-release/outdated` lists Cloudflare VMs whose `current_worker_version_id` has not converged.
  - `GET /v1/admin/vm/ops/stuck` lists Cloudflare VM records in `creating`, `reviving`, `archiving`, `waking`, or `failed`, with `ops_age_ms` and `last_error` when present.
  - `GET /v1/admin/vm/ops/keepalive-leaks` lists Cloudflare records that still imply provider keepAlive but have no live Salix attachment.
    Use it after teardown, idle archive rollout, and node drains. After archive, the expected state is an `archived` record that does not appear here.
  - Worker and Gateway logs emit `sandbox_ensure`, `sandbox_status`, `sandbox_connect`, `sandbox_keepalive`, `sandbox_destroy`, `sandbox_checkpoint`, and `sandbox_restore`
    with `worker_version_id`, `worker_version_tag`, `gateway_build_id`, and `connector_image_version`.
  - A stopped Container logs `sandbox_stopped` with its exit code or the monitor's error, and whether Salix commanded it (`requested`).
    The same record is `last_stop` in the Gateway's control observation.
    Exit code 65 means a waking Container could not restore its archive and started no station.
    The Gateway keeps the last uncommanded stop as `last_uncommanded_stop`. A later archive's destroy does not replace it.
  - When Salix finds a ready VM's Container stopped, it copies that stop into the record's `container_loss.stop` and its log line:
    exit code, monitor error, `started_at`, the Worker and image versions, and `seen_by`.
    `seen_by: "sdk"` with `started_at: null` means the Durable Object that started the Container did not see it end.
    `recorded: false` means the Gateway kept no stop for it.
  - Salix CloudVM records store the Worker metadata under `provider_spec.cloudflare_worker`. Use it to tie one VM call to the Worker and connector image that served it.
  - Cloudflare attachments use the shared Connector protocol. A disconnect ends that connection's pending requests and streams.
    Interrupted non-idempotent calls return `vm_reconnecting`. Salix does not replay them.
  - Connector archive and native checkpoint or restore failures go to VM `last_error` and Gateway operation logs.
    The Connector archive is the durable recovery source. Native checkpoint or snapshot is an optional provider-local speedup.
- **Background singletons**: recovery, GC, timers, and schedules are lease-gated. Check `ctl/singletons/*.json` to see holders.
- **IM provider connects**: configure provider-specific connects per group.
  Inbound provider events enter the group router session through SalixIM.
- **Migration from Go willow**: export each agent with `willow-salix-export -db <agent.db>` (built from the willow repo).
  Import with `SalixMigrate.Import.import_agent/3`. Verify the one-way routing flag with `SalixMigrate.Cutover.route/1`.
  A successful import writes `migrated: true`. Use `mark_migrated/1` only for a separately staged record whose flag is still false.
  Roll out externally prepared records with `SalixMigrate.Cohort`.
- **Backups and DR**: back up PostgreSQL, object storage, and persistent encryption keys together.
  Include ClickHouse and Redis as their configured use needs. Bucket backups alone cannot restore the product.
  Verify a restore with the matching release before you admit users.

## CI

See [`.github/CI.md`](../.github/CI.md).
`.github/workflows/systems-docker.yml` copies each private input in `private/sources.lock.json` to `private/<name>` before the build.
Builds without these inputs, including self-hosted builds, have no live ASR provider.

## Cloudflare Group VM archives

Cloudflare Group disks are temporary, disposable storage. Follow the [Cloud VM data policy](../docs/compute-devices.md#cloud-vm-data-policy).
The Connector tries a full archive before an idle stop and an ordinary image replacement.
Fault recovery can try a smaller checkpoint after sealing and quiet confirmation.
The archive excludes generated caches and `.codex/tmp` under the managed legacy home and Connector home.
It keeps Codex credentials, configuration, Session history, dependency installation trees, local changes, Git metadata, settings, credentials, the Salix managed runtime, and other ignored files.
An Agent can use `env.dependency_installations` to declare repository packages or manually installed tools. A declaration does not exclude a directory.
Restore keeps internal symbolic links. It rejects links and extraction paths that escape the workspace.
After a restore from an older archive, supported omitted packages install in the background.
The Agent can read progress, stop the installer, or install packages in the normal shell. An installation failure does not block VM commands.

Recovery archives omit Agent workspaces, managed dependency packages, and workspace sweep archives.
They keep native continuation and opaque auth and configuration files when available, as best-effort recovery material.
A failed archive or restore permits exact owner-led destruction and rebuild. Do not repeat failures only to keep local files.
Do not restore old pending execution after a destructive reset. Keep central Salix Sessions and unknown outcomes under their owners.
Report interrupted work, lost local files, and any required authentication.
See the [Gateway release procedure](cloudflare/salix-vm-gateway/RELEASE.md#container-image-release) for owner operations.

New Cloudflare archives use direct Connector transfer to R2 with short-lived URLs that Salix signs.
Set `cloud_vm_archives.r2` in the environment config with the endpoint, bucket, access key ID, and secret access key.
Old Connector images export to Salix S3 until their image updates. Old Salix S3 generations stay readable until a later archive replaces them.
Restore uses a complete Salix S3 copy of the same generation if R2 cannot serve it.

After Comma Deployment publishes the mainline Comma release, its Gateway image job runs automatically.
The [Gateway release procedure](cloudflare/salix-vm-gateway/RELEASE.md) owns the release contract.
Cloudflare Group disk loss has product-owner approval. Deployment-wide shutdown still needs the documented human approval.
