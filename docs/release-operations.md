# Release operations

## Authority and artifacts

Use `Comma Deployment` to stage mainline artifacts and promote staging-proven releases.
It rolls the VMM Gateway before Salix. See [Gateway release](../k8s/salix-vmm-gateway/README.md#release).
Merge approval is separate from deployment approval. Unmerged artifacts and recovery snapshots are ineligible for promotion.
Check deployed revisions before claiming a live fix.

Prepare needs a positive `deployed` Comma Helm revision. Install and adopt separately. Let Helm manage topology.

## Marketing website

Website CI builds and smoke-tests `website/`. Website-only edits skip client E2E and Electron builds. Shared build inputs select both.
The CI build installs Chromium and Linux dependencies for the hero capture, which Workers Builds cannot do.
Main deployment downloads that run's artifact and deploys with Wrangler. PR builds do not deploy.
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

Keep Worker Git builds disconnected (Settings > Builds). Keep the Worker and domain. Do not use branch deployments.
Check DNS and routes before you connect a domain. Wrangler returns 404 for unknown paths.
Verify localized pages, docs, downloads, and cache headers.

## Desktop update feeds

Before upload, `release-storage.mjs` adds the live feed's deltas to the packed Velopack feed. Production adds the active feed's deltas to the pending feed.
A feed lists the newest 30 deltas. R2 keeps older packages.

## Rollout policy and human shutdown approval

Graceful rolling updates are the default. Mixed versions may briefly interrupt requests, connections, or features.
Pods join the placement ring only after all applications start and leave it in preStop while another pod is ready.
The release must keep durable product facts and restore all services within the [hard budgets](#hard-budgets).
Do not add compatibility state for continuous rollout reachability.
A failed dependency must give a bounded, actionable error. This is not full recovery.
Verify core, provider and Agent admission completion.
Health reads run concurrently. Each ordinal still needs two complete successes, 20 seconds apart.

Only an incompatible durable-data cutover justifies scale-to-zero or deployment-wide shutdown, not temporary mixed-version errors.
Staging requires human approval before the release executor runs online migrations for a shutdown plan or fences writers.
This includes manifest-selected `exclusive`, the Session lifecycle hard cut, and the dedicated legacy shutdown path.
Production keeps its existing release and data approval requirements.

Shutdown plans create one approval issue before migrations or writer fencing. Online releases skip this issue.
Issue title and body contain `HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
The body names environment, release ID, image, chart, manifest, pending migrations, and Session hard-cut setting.

1. Start Comma Deployment normally. No issue ID or comment ID is required.
2. Open the issue link from the workflow log or Slack notice.
3. Check the shutdown reason, durable facts, disposable scope, required backup evidence, and recovery procedure in the linked change.
4. A human with repository write, maintain, or admin permission posts a standalone approval comment.

Accepted replies include `yes`, `ok`, `okay`, `lgtm`, `approved`, `go ahead`, `同意`, and `批准`.
Case, surrounding whitespace, and a final period or exclamation mark do not matter.
Questions, conditional replies, quoted text, edited comments, and bot accounts do not approve.
Agents must not post, edit, or impersonate approval, including through a human account or token.
GitHub cannot tell a human from an agent that uses the human's credentials, so this prohibition stays necessary.

The executor checks only this release issue for at most 10 minutes, before the shutdown budget starts.
Issue closure, generated title/body edits, API failure, comment overflow, or timeout stops deployment before shutdown.
A later invocation creates a new issue. Old comments cannot approve another invocation or candidate.
Issue creation is not retried after an uncertain API response. The issue stays as an audit record.
Do not bypass the executor with manual scale, shutdown, or Helm maintenance commands without the same human approval.
Exclusive maintenance sets replicas to zero, then overlaps owned Pods' normal grace periods. Migration waits for all old writers to disappear.
Maintenance upgrades (also during repair) skip all Helm readiness waits. Apply/Verify check collector readiness later.

Slack replies do not approve a release.

Recovery can restore the captured pre-cutover snapshot, or keep incompatible old writers stopped after cutover, without a new approval.
An expired request does not authorize a new shutdown. Re-entry before cutover creates a new request.

## State and manifest

Active release state is schema V4 only.
V1 through V3, missing or unknown schemas, unknown fields, and retired phases fail closed before mutation.
The plan and manifest stay V2. Bundles and environment specs stay V1. These versions are independent.

A V3-to-V4 transition requires a terminal `succeeded` or `recovered` state, no active runner, and the exact recorded positive deployed Helm revision.
An approved one-time operation changes only `schemaVersion` under a `resourceVersion` fence.
Record the preconditions. Verify the exact new body, V4 status, and V3 rejection before further mutation.
After any V4 release mutation starts, do not restore V3 or run a V3 binary.
Fresh environments create V4 directly. Normal commands never convert old state.

The manifest is `systems/apps/comma/priv/release/migration-manifest-v2.json`.
`stepDefaults` expands before validation, digest, planning, or execution.
The executor receives the plan's digest, mode, exact pending IDs, phases, compatibility, budgets, postconditions, and named repairs unchanged.
Do not infer authority from migration filenames, version cutoffs, globs, SQL, or a V1 projection.
Missing IDs, checksum drift, unknown fields, invalid order, and missing safety facts fail planning.
Provider work stays outside the manifest.

## Adding or repairing a migration

Every PostgreSQL or ClickHouse migration enters the manifest in the same change.
Choose `expand`, `contract`, `exclusive`, or `local_seed`.
Declare owner, exact source, version and checksum, compatibility, idempotency, transactionality, timeout and lock budgets, destructiveness, backup need, rollback, postconditions, and repair.
Nontransactional steps need idempotent repair and explicit schema postconditions.
`destructive` records data removal. `backupRequired` records whether the owner requires preservation of durable facts.
Durable facts require backups. Owner-approved disposable projections do not.
Contract steps stay ledger facts but cannot run in an ordinary plan. A later contract operation needs exact selection and the required data and backup evidence.

Comma, Billing, and BFT share `schema_migrations`. SalixStore uses `salix_schema_migrations` with its own owner allowlist.
Foreign ledger versions are contamination, not implicit completion.
Manifest order is authoritative. Do not use numeric order to bypass cross-owner prerequisites.
The executor permits manifest-required lower Ecto versions, not undeclared versions or automatic `down`.
Use the named manifest repair for the exact failure. Do not clear ledger rows generically.

Pending reserved legacy steps give `blocked_legacy` before workload mutation.
Do not turn this into ordinary exclusive mode or scale Comma to zero.
Only the dedicated legacy operation can select its three frozen Salix IDs. New migrations cannot declare `legacy`.
That path keeps maintenance, writer absence, cutover fence, exact execution, and candidate verification.
It does not authorize unrelated migration IDs or rollback after the fence.

## Data safety and recovery

Keep durable product facts. Do not add dual writes or compatibility state to keep old writers serving.
Resolve the exact destructive target with a bounded read, and resolve disposal through the owning contract.
The [Cloud VM data policy](compute-devices.md#cloud-vm-data-policy) permits local Group disk loss.
Database deletion and deployment-wide shutdown keep their separate approvals.

A destructive durable-data approval must name:

1. A fresh backup identifier and time for the exact environment and store.
2. An isolated restore rehearsal, its duration, and its result.
3. The manifest owner and Data/Runtime approver.
4. Exact migration IDs, checksums, and the convergence budget.

An owner-approved disposable projection or VM scope instead needs its exact bound, mainline rebuild source, and enrollment, authentication, and readiness conditions.
PITR alone is not restore evidence. ClickHouse destructive migrations need a recorded backup and isolated restore rehearsal.

Before cutover, recovery can restore the approved serving snapshot.
After cutover, keep old writers stopped and repair forward at the safe maintenance or candidate revision.
Expiry does not authorize database `down`, PITR, or incompatible old writers.

### Salix PostgreSQL authority cutover

The Session unit covers Agent ownership, Session birth/state, accepted inputs, CapabilityRequests, due work, and history targets.
The Conversation unit includes metadata, Messages, Participants, provider receipts, consumer targets, and search jobs.
Stop old writers, callbacks, and maintenance before import. Deployment-wide shutdown requires the existing exclusive-mode human approval.

Preserve identities, epochs, deduplication, source frontiers, tool and reply obligations, receipt outcomes, deletion facts, and archive locations.
Clear the old Agent lease and node. Its new owner must claim a higher epoch.
Attachments and sealed history stay in S3. Hot snapshots and pending work are durable facts.
Only candidate discovery and search/history projections may rebuild from canonical facts.

With external delivery paused, the old Conversation owner must settle prepared publication before the source freeze.
Unsettled reservations/publications stop import and identify the object. Do not discard them or invent published sequences.
Exclusive step `salix-20261028000300` imports S/C pages until both unit markers report `complete`.
Each page commits facts and progress together. Retries preserve identities and sequences.
C imports scan metadata, segments, then mixed JSON. GET limits: 48 for C, 64 across S/C.
Old cursors retain order. Complete units do not rerun.
The Ecto ledger commits after both imports. Schema/S3-projection restore ledgers cannot replace it.
Release Jobs start database/S3 dependencies. Legacy conversion keeps its task supervisor without online provider workers.
New writers require complete import, readable history, resumable accepted work, and preserved provider-unknown outcomes.

Read-only `Comma.Release.inventory_salix_pg(:s, cursor, opts)` or `:c` validates source codecs, not import transactions.
After writer freeze, `Comma.Release.import_salix_pg(:s, confirm_no_writers: true, max_pages: 1)` or `:c` resumes the unit marker.
For unresolved birth-only/external markers, `known_sessions` maps exact keys to original Session IDs. Never use hashes as IDs.

Measure inventory, import time, WAL growth, and restore against the hard budgets before scheduling.
Local samples do not prove the production window. Backup and restore requirements still apply.
If old S3 writers ran again, reset the approved imported target scope, unit progress, and conversion ledger before importing the fresh freeze.
Never reuse old cursors or completion markers after source writes resume.
Delete old hot objects only from an approved exact inventory after retention and recovery verification.

### Agent VMM registration cutover

Expand step `salix-20261103150000` runs online. One transaction with a 5-second lock budget folds each Installation Operation into its preassigned Registration. It preserves request idempotency, Host commitments, credentials, delivery targets and initial Shell keys.
Old tickets, enrollment tokens and ACK capabilities expire at this commit; they never reopen a Host-bound Registration for first claim.
Until old Pods leave, a database fence fails their installation writes as unavailable. Their Host authentication and other reads keep serving. Retry an install on a new Pod.
Failure before commit rolls back. Retry the same migration. After commit, repair forward.
Contract step `salix-20261103150100` removes the fenced table and the enrollment column. It needs exact selection and a recorded backup, after no old Pod remains.

### Pre-cutover runtime repair

For a broken online snapshot, dispatch Comma Deployment with the recorded `repair_release_id` and approved mainline artifacts.
CLI: `comma-release repair --replace-release OLD_ID` with a new `COMMA_RELEASE_ID`.
Repair requires `recovering`, no cutover, and no lifecycle hard cut. New plans must stay online.
It settles attempts, saves the full previous state in an immutable ConfigMap, then transfers execution with compare-and-swap.
The archived `recovering` state is evidence without execution authority.
New ledger plans can add steps but cannot repeat completed migrations.
Repair keeps the snapshot, replicas, and PVCs. With partition 0, it deletes only owned, unready older-revision Pods. Kubernetes rolls Ready Pods normally.
UID and resourceVersion preconditions protect successors. A deadline bounds replacement.
Full verification and provider, Agent, and Runtime convergence stay required.

### Forward repair

Ordinary `prepare`, workflow reruns, and `reconcile` do not resume `forward_only`.
Do not replace its durable release ID or candidate facts with a new attempt.
Inspect `comma-release status` and resolve the named migration or candidate failure first.
Use the same environment, immutable chart, candidate configuration, and recorded `COMMA_RELEASE_ID`.
Keep the original Session hard-cut setting when that release requires it.
Select the command from the recorded `forwardPhase`:

| Recorded phase | Resume command |
| --- | --- |
| `cutover` | `comma-release migrate --resume-forward` |
| `applying` | `comma-release apply --resume-forward` |
| `verifying` | `comma-release verify --resume-forward` |

Add `--retry-failed` only after you repair a confirmed failed cutover attempt.
After resume, run `apply` and `verify` in order without `--resume-forward`.
Then run `sync-provider` and `finish-agent-configuration`, and verify completion.
If a phase fails, run `recover` with the same release ID before further repair.
For `applying` or its `forward_only` state, dispatch `Comma Forward Repair` from `main` with the environment and recorded release ID. Repair cutover failures first.

## Hard budgets

Comma budgets follow. CF retirement has no drain gate or image job. See [Cloud VM cutover](agent-runtime.md#cloud-vm-cutover).
Contract step `bridge-20261105120001` drops `projects.vm_enabled`, the Agent Swarm's Cloud VM switch. It needs exact selection and a recorded backup, after no old BFT Pod remains.

| Operation | Staging | Production | Approval/response |
| --- | --- | --- | --- |
| Rollout and convergence | 20 minutes | 20 minutes | Platform release operator and on-call |
| Writer-fenced cutover | 10 minutes | 5 minutes | Data/Runtime approval, Platform operation, both respond |
| Migration repair before escalation | 20 minutes | 10 minutes | Manifest owner and Data/Runtime on-call |
| Provider convergence | 30 minutes | 15 minutes | BFT provider on-call |

First Salix PG production cutover: owner-approved 15-minute outage total for import, startup, provider recovery and Agent admission.
Prove this total with production-scale data and comparable resources before scheduling.
Salix release-only pool: three connections for one migration lock and two import writers.
DB requests: 120-second cap including queue wait. Adaptive queues can reject earlier. Serving defaults unchanged.

Cutover budgets bound completion, not continuous availability.
On expiry, stop promotion, keep the safe fenced Helm revision, and page Platform and Data/Runtime.

## Provider and Agent convergence

Core success does not depend on provider convergence.
While providers are pending or failed, serve the existing configuration and reject provider-changing admin operations as temporarily unavailable.
Do not roll back the application or database after core success for this condition.

Budget exhaustion sets `provider_degraded`, pages provider on-call, and keeps core `succeeded`.
A later reconcile resumes from durable facts in a fresh bounded window. No background observer runs without a bound.

After core and provider success and old-writer exit, the serving RPC transfers Agent configuration, then Group Compute.
Group transactions copy up to 20 objects and the cursor. Sources stay intact.
The handoff converts known legacy Cloudflare Group locations and old writers' pending start claims, at most 100 rows per page. Unknown locations need exact repair.
Then it closes the station roster window.
Agent admission gates mutations. Group admission gates reads and writes until the last page.
Budget: staging 10 minutes, production 5 minutes.
Transient transport errors, including `kubectl error: EOF`, retry the same page within that budget.
Failure exits nonzero and core stays `succeeded`. Repair, then run `comma-release finish-agent-configuration`.
After admission, keep old writers stopped. Group repair is forward-only. Agent rollback stays fence-aware.
Empty-store bootstrap cannot repair hosted stores.

## Secrets and packaged files

`comma-release` owns immutable content-addressed candidate Kubernetes Secrets, their references, and bounded garbage collection.
Helm owns stable workload references and non-secret checksums, not Secret payloads.
Gateway operations owns TLS inputs and the stable Gateway reference. Comma release materializes the selected TLS candidate.
Never put payloads in Helm values or history, rendered manifests, release state, logs, ConfigMaps, or chart artifacts.

VMM gateway secrets have their own owner under `k8s/salix-vmm-gateway/`.
Release tooling pins Helm and archive checksums. Do not install `latest`.

## Completion evidence

Record exact candidate and deployed revisions, final core and provider state, fence status, data verification, required re-enrollment, and the elapsed convergence budget.
Workflow, migration, or Pod health alone does not prove convergence. Old reports do not prove current state.

## Self-hosting with Compose

The root `compose.yaml` owns an independent single-node installation. It does not deploy to hosted staging or production.
Read [the Compose guide](../systems/DEPLOYMENT.md#self-hosted-compose) before you install or upgrade.

Stop serving containers before schema upgrades. Keep all named volumes.
The offline initializer uses the existing migration and admission owners.
It accepts an empty Comma import only after bounded table-emptiness checks. It refuses an unfinished Bridge configuration handoff.
Existing installations keep users, workspaces, conversations, keys, and grants.

Back up PostgreSQL, object storage, ClickHouse, Redis, and the configuration volume together while the instance is stopped.
The configuration volume holds the subscription encryption key and authentication secrets.
Restore to isolated volumes and verify login and stored conversations before you switch users.
