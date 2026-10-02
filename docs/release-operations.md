# Release operations

## Authority and artifacts

Use approved mainline artifacts with `comma-release reconcile`: published image/chart on staging, staging-proven promotion on production.
Merge approval does not authorize deployment. Never deploy PR artifacts or use tag overrides to bypass mainline publication.
Recovery may restore a historical branch snapshot, but that snapshot is not a later release candidate. Read back the deployed revision before claiming a fix is live.

The coordinator fences manifest V2 attempts, applies Helm, verifies the app, then records core success before provider convergence.
Normal prepare requires positive `deployed` Helm revision `comma`. Installation and adoption are separate. Helm owns desired state. No manual topology shortcuts.

## Marketing website

Website CI builds and smoke-tests `website/`. Website-only edits skip client E2E and Electron builds; shared build inputs select both.
The build installs Chromium and Linux dependencies for the hero capture. Workers Builds cannot install them.
Main deployment downloads that run's artifact and uses Wrangler. PR builds do not deploy.
The `prod` environment's `COMMA_WEBSITE_CLOUDFLARE_API_TOKEN` needs Worker and custom-domain permissions for this account and zone.

```text
Worker: comma-website-static
Account: 0367b0648b476f564267fd6f4c2d515e
Domain: comma.surf
Artifact directory: website/dist
Workflow: .github/workflows/client-build.yml
Build command (from repository root): pnpm build:website:cloudflare
Deploy command (from repository root): pnpm deploy:website
```

After merge, disconnect Worker Git in Settings > Builds. Keep Worker and domain. No branch deployment.
Check DNS/routes before domain connection. Wrangler returns 404 for unknown paths. Verify localized pages, docs, downloads, and cache headers.

## Rollout policy and human shutdown approval

This section owns cluster rollout policy.
Graceful rolling updates are the default, including when some services or features become temporarily unavailable.
Requests, connections, or logic can fail while old and new processes overlap.
The release must preserve durable product facts and restore all services within the budgets below.
Do not require continuous reachability during rollout or add compatibility state solely to provide it.
A failed dependency must produce a bounded, actionable failure. It does not count as full service recovery.
Core success alone does not prove full convergence. Verify provider and Agent admission completion too.

Avoid scale-to-zero and deployment-wide shutdown. An incompatible durable-data cutover can require this exception.
Temporary mixed-version errors alone do not justify it.
Staging requires human approval before the release executor runs online migrations for a shutdown plan or fences writers.
This includes manifest-selected `exclusive`, the Session lifecycle hard cut, and a dedicated legacy shutdown path.
Production retains its existing release and data approval requirements.

The executor detects shutdown from the plan and creates one approval issue before migrations or the writer fence.
Online rolling releases do not create an issue or wait for approval.
The issue title and body contain `HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
Its body names the environment, release ID, image, chart, manifest, pending migrations, and Session hard-cut setting.

1. Start Comma Deployment normally. No issue ID or comment ID is required.
2. Open the issue link from the workflow log or Slack notice.
3. Check the shutdown reason, durable facts, disposable scope, required backup evidence, and recovery procedure in the linked change.
4. A human with repository write, maintain, or admin permission must post a standalone approval comment.

Accepted replies include `yes`, `ok`, `okay`, `lgtm`, `approved`, `go ahead`, `同意`, and `批准`.
Capitalization, surrounding whitespace, and final periods or exclamation marks do not matter.
Questions, conditional replies, quoted text, edited comments, and bot accounts do not approve.
Agents must not post, edit, or impersonate approval, including through a human account or token.
GitHub cannot distinguish a human from an agent using that human's credentials. The explicit agent prohibition remains necessary.

The executor waits at most 10 minutes before starting the shutdown budget.
It checks only the issue for this release.
Closing the issue, editing its generated title or body, API failure, comment overflow, or timeout stops deployment before shutdown.
A later invocation creates a new issue. Old comments cannot approve another invocation or candidate.
Issue creation is not retried after an uncertain API response. The issue remains as an audit record after the wait ends.
For CLI use, set `GITHUB_REPOSITORY` and authenticate the official `gh` CLI with `GH_TOKEN`.
The workflow supplies its own token with `issues: write` and repository metadata access.
Do not bypass the executor with manual scale, shutdown, or Helm maintenance commands without the same human approval.

### Slack approval notice

The approval issue link also goes to Slack. Slack replies do not approve a release.
A notification failure warns the operator; the GitHub approval wait continues.

Recovery retains authority to restore the captured pre-cutover snapshot or keep incompatible old writers stopped after cutover.
It must not wait for a new approval to preserve data after the cutover fence.
An expired request does not authorize a new shutdown. Re-entry before cutover creates a new request.

## State and manifest

Active release state is schema V4 only.
V1 through V3, missing/unknown schemas, unknown fields, and retired phases fail closed before mutation.
The migration plan and manifest remain V2. Candidate bundles and environment specs remain V1.
These contracts have independent versions.

A V3-to-V4 transition requires a terminal `succeeded` or `recovered` state, no active runner,
and the exact recorded positive deployed Helm revision.
An approved one-time operation changes only `schemaVersion` under a `resourceVersion` fence.
Record the preconditions and verify the exact new body, V4 status, and V3 rejection before further mutation.
Once any V4 release mutation starts, do not restore V3 or run a V3 binary.
Fresh environments create V4 directly. Normal commands never convert old state.

The manifest is `systems/apps/comma/priv/release/migration-manifest-v2.json`.
`stepDefaults` expands before validation, digest, planning, or execution.
The complete plan carries digest, required mode, exact pending IDs, phases, compatibility,
budgets, postconditions, and named repairs unchanged to the executor.
Do not infer authority from migration filenames, version cutoffs, globs, SQL, or a V1 projection.
Missing IDs, checksum drift, unknown fields, invalid ordering, and missing safety facts fail planning.
Provider work stays outside the migration manifest.

## Adding or repairing a migration

Every PostgreSQL or ClickHouse migration must enter the manifest in the same change.
Choose `expand`, `contract`, `exclusive`, or `local_seed`.
Declare owner, exact source/version/checksum, compatibility, idempotency, transactionality,
timeout/lock budgets, destructiveness, backup need, rollback, postconditions, and repair.
Nontransactional steps need idempotent repair and explicit schema postconditions.
Contract steps remain ledger facts but cannot execute in an ordinary plan.
A later contract operation requires exact selection and the required data/backup evidence.

Comma, Billing, and BFT share `schema_migrations`.
SalixStore uses `salix_schema_migrations` with its own owner allowlist.
Foreign ledger versions are contamination, not implicit completion.
Manifest ordering is authoritative. Do not use numeric ordering to bypass cross-owner prerequisites.
The exact executor permits manifest-required lower numeric Ecto versions, not undeclared versions or automatic `down`.
Use the named manifest repair for the exact failure. Do not clear ledger rows generically.

Pending reserved legacy steps produce `blocked_legacy` before workload mutation.
Do not translate this into ordinary exclusive mode or scale Comma to zero.
Only the existing dedicated legacy operation can select its three frozen Salix IDs.
New migrations cannot declare `legacy`.
The dedicated path retains maintenance, writer absence, cutover fence, exact execution, and candidate verification.
It does not authorize unrelated migration IDs or rollback after the fence.

## Data safety and recovery

Preserve durable product facts. Follow the rollout policy above for temporary unavailability and shutdown approval.
Do not add dual writes or compatibility-only state merely to keep old writers serving.
Resolve the exact destructive target with a bounded read before execution.
A cache, disk, credential store, or projection is not automatically disposable.

A destructive durable-data approval must name:

1. A fresh backup identifier and time for the exact environment/store.
2. An isolated restore rehearsal, duration, and verification result.
3. The manifest owner and Data/Runtime approver.
4. Exact migration IDs/checksums and the convergence budget.

An owner-approved disposable projection or VM scope instead requires its exact bound,
mainline rebuild source, and enrollment, authentication, and readiness conditions.
PITR enablement alone is not restore evidence.
ClickHouse destructive migrations require a recorded backup and isolated restore rehearsal.

Before the cutover fence, recovery can restore the approved captured serving snapshot.
After the fence, keep old writers stopped and use forward repair at the safe maintenance/candidate revision.
Budget expiry never authorizes database `down`, PITR, or an incompatible old writer restart.

### Pre-cutover runtime repair

For a broken online snapshot, dispatch Comma Deployment with the recorded `repair_release_id` and approved mainline artifacts.
CLI: `comma-release repair --replace-release OLD_ID`. Set a new `COMMA_RELEASE_ID`.
Repair requires `recovering`, no cutover, and no lifecycle hard cut. New plans must remain online.
It settles attempts, saves the full previous state in an immutable ConfigMap, then CAS-transfers execution.
The archive retains `recovering` as evidence without execution authority.
New ledger plans may add steps but cannot repeat completed migrations. Normal manifest drift checks remain unchanged.
Repair keeps the snapshot, replicas, and PVCs. With partition 0, it manually deletes only owned, unready older-revision Pods.
Kubernetes still rolls Ready Pods normally.
UID/resourceVersion preconditions protect successors. A deadline bounds replacement.
Full verification and provider, Agent, and Runtime convergence remain required.

### Forward repair

Ordinary `prepare`, workflow reruns, and `reconcile` do not resume `forward_only`.
Do not replace its durable release ID or candidate facts with a new attempt.
Inspect `comma-release status` and resolve the named migration or candidate failure first.
Use the same environment, immutable chart, candidate configuration, and recorded `COMMA_RELEASE_ID`.
Keep the original Session hard-cut setting when that release requires it.
Select the command from the recorded `forwardPhase`:

| Recorded phase | Resume command                           |
| -------------- | ---------------------------------------- |
| `cutover`      | `comma-release migrate --resume-forward` |
| `applying`     | `comma-release apply --resume-forward`   |
| `verifying`    | `comma-release verify --resume-forward`  |

Add `--retry-failed` only after repairing a confirmed failed cutover attempt.
After resume, run `apply` and `verify` in order without `--resume-forward`.
Run `sync-provider`, then `finish-agent-configuration`; verify completion below.
If a phase fails, run `recover` with the same release ID before further repair.
For Staging `applying`, dispatch `Comma Forward Repair` from `main` with the recorded release ID. It checks the phase and runs `apply`, `verify`, provider sync, and Agent configuration completion with the recorded artifacts.

## Hard budgets

These budgets cover the Comma release coordinator. The separate Gateway Container
image release uses one 75-minute Group drain budget for both profiles; see the
[Gateway release procedure](../systems/cloudflare/salix-vm-gateway/RELEASE.md).

| Operation                          | Staging    | Production | Approval/response                                       |
| ---------------------------------- | ---------- | ---------- | ------------------------------------------------------- |
| Rollout and convergence            | 20 minutes | 20 minutes | Platform release operator and on-call                   |
| Writer-fenced cutover              | 10 minutes | 5 minutes  | Data/Runtime approval, Platform operation, both respond |
| Migration repair before escalation | 20 minutes | 10 minutes | Manifest owner and Data/Runtime on-call                 |
| Provider convergence               | 30 minutes | 15 minutes | BFT provider on-call                                    |

A cutover budget bounds completion, not uninterrupted availability.
On expiry, stop promotion, retain the safe fenced Helm revision, and page Platform and Data/Runtime.
The external Cloud Monitoring release watchdog reads bounded summaries and Helm facts without mutation.
Its detection objective is five minutes and paging objective ten minutes.
It alerts on stuck, recovery failure, forward-only, provider degradation, and exclusive budget expiry.

## Provider and Agent convergence

Core success is independent of provider convergence.
While providers are pending or failed, serve existing configuration and reject provider-changing admin operations as temporarily unavailable.
Do not roll back the application or database after core success for this condition.

The coordinator polls its provider Job every five seconds.
One high-level wake can dispatch at most three deterministic attempts within the environment budget.
It records completion before exit.
Exhaustion projects `provider_degraded` and pages provider on-call while core stays `succeeded`.
A later reconcile resumes durable facts within a fresh bounded window.
There is no hidden unbounded observer or 24-hour worker.

After core/provider success and old-writer exit, the serving RPC transfers Agent configuration, then Group Compute.
Group transactions copy up to 20 objects and the cursor. Sources stay intact.
The same handoff then converts known legacy Cloudflare Group locations and pending start claims left by old writers during rollout, up to 100 rows per page. Unknown locations remain unresolved for exact repair.
Agent admission gates mutations. Group admission gates reads/writes until the last page.
Budget: staging 10 minutes, production 5 minutes.
Failure exits nonzero. Core stays `succeeded`. Repair and run `comma-release finish-agent-configuration`.
After admission, keep old writers stopped. Group repair is forward-only. Agent rollback remains fence-aware.
Local empty-store bootstrap is not a hosted repair path.

## Secrets and packaged files

`comma-release` owns immutable content-addressed candidate Kubernetes Secrets, references, and bounded garbage collection.
Helm owns stable workload references and non-secret checksums, not Secret payload objects.
Gateway operations owns TLS inputs and the stable Gateway reference.
Comma release materializes the selected TLS candidate.
Never put payloads in Helm values/history, rendered manifests, release state, logs, ConfigMaps, or chart artifacts.

Comma Runtime owns `resources/salix-system-files` in the immutable image.
Comma candidate Secrets do not use the deferred CSI/SecretSync/IAM migration.
VMM gateway secrets have their independent owner under `k8s/salix-vmm-gateway/`.
The pinned Helm client and archive checksums live in the release tooling.
Do not install `latest` or copy a new pin into docs without its required validation.

## Completion evidence

Record exact candidate and deployed revisions, final core/provider state, fence status,
data verification, required re-enrollment, and the elapsed convergence budget.
Workflow, migration, or Pod health alone does not prove convergence. Historical reports do not prove current state.

## Workload image update

After core success and Agent configuration handoff, `comma-release reconcile` publishes the desired external Runtime catalog.
A bounded Job reads the catalog from the successful release's immutable server image.
`compute_runtime_release` stores this release-owned projection. It does not own release success.
The existing Helm serving revision orders publications. A late older Job cannot replace a newer target.
Runtime digests only test equality. An unrelated server release with unchanged Runtime images causes no replacement.

The Compute reconciler selects mismatched Codex, Claude, and Pi Workloads through its existing bounded cursor.
Each node runs at most four provider tasks. Host reconnect wakes an exact Workload, and periodic reconciliation covers missed notifications.
An active `Workload.runtime_update` finishes its persisted target before another update starts.
The updater preserves Workload identity, accepted input, Session bindings, credentials, and named volumes.
It imports the image, confirms quiet, pauses new input claims, drains accepted work, stops the exact quiesced instance, and verifies its replacement.
Memory and tmpfs do not survive replacement.

A disconnected running Connector cannot supply quiet evidence. Automatic updates remain in preparation without pausing input or stopping children.
An unsupported quiet operation also waits. Host connectivity alone does not prove that native work is idle.
If the Host confirms the source container is absent, replacement proceeds only after all in-flight input settles.
After the pause, all stop attempts still require quiet evidence and current instance fencing.
Recoverable failures retry through the existing scheduler. Automatic updates do not park solely because a drain or total deadline expires.
Storage capacity rejection and explicit provider action requirements still require operator repair.
Manual updates retain their explicit attempt budgets. Cancellation suppresses automatic admission for that target until the target changes.

Core deployment success and Runtime convergence are separate results.
If publication fails, retry `comma-release publish-runtime-release` against the successful release state.
Read `Comma.Release.runtime_release_status()` through release RPC for a page of up to 50 Workloads.
Pass its `next_cursor` to the next call. Each item reports `complete`, `waiting`, or `failed`, its phase, and its last error.
This is a paged observation, not an atomic fleet snapshot or a proof of native task continuation.
Use an affected task to verify the live path after rollout.
The [VMM operations skill](../.codex/skills/vmm-ops/SKILL.md) gives exact retry, cancel, and forward-repair commands.

## Self-hosting with Compose

The root `compose.yaml` owns an independent single-node installation.
It does not deploy to the hosted staging or production environments.
Read [the Compose guide](../systems/DEPLOYMENT.md#self-hosted-compose) before installation or upgrade.

Stop serving containers before schema upgrades. Preserve all named volumes.
The offline initializer uses existing migration and admission owners.
It accepts an empty Comma import only after bounded table-emptiness checks.
It refuses an unfinished Bridge configuration handoff.
Existing installations retain users, workspaces, conversations, keys, and grants.

Back up PostgreSQL, object storage, ClickHouse, Redis, and the configuration volume together while the instance is stopped.
The configuration volume contains the subscription encryption key and authentication secrets.
Restore to isolated volumes and verify login and stored conversations before switching users.
