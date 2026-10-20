# Release operations

## Authority and artifacts

Use approved mainline artifacts with `comma-release reconcile`: the published image and chart on staging, a staging-proven promotion on production.
Merge approval does not authorize deployment. Never deploy PR artifacts or use tag overrides to bypass mainline publication.
Recovery can restore a historical branch snapshot. That snapshot is not a later release candidate.
Read back the deployed revision before you claim a fix is live.

Normal prepare requires a positive `deployed` Helm revision of `comma`. Installation and adoption are separate. Helm owns desired state. Do not change topology manually.

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

## Rollout policy and human shutdown approval

This section owns cluster rollout policy.
Graceful rolling updates are the default, even when some services or features are briefly unavailable.
Requests, connections, or logic can fail while old and new processes overlap.
The release must keep durable product facts and restore all services within the [hard budgets](#hard-budgets).
Do not require continuous reachability during rollout or add compatibility state only to provide it.
A failed dependency must give a bounded, actionable failure. That is not full service recovery.
Core success alone does not prove convergence. Also verify provider and Agent admission completion.

Avoid scale-to-zero and deployment-wide shutdown. Only an incompatible durable-data cutover can justify it. Temporary mixed-version errors do not.
Staging requires human approval before the release executor runs online migrations for a shutdown plan or fences writers.
This includes manifest-selected `exclusive`, the Session lifecycle hard cut, and the dedicated legacy shutdown path.
Production keeps its existing release and data approval requirements.

The executor detects shutdown from the plan and creates one approval issue before migrations or the writer fence.
Online rolling releases do not create an issue or wait.
The issue title and body contain `HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
The body names the environment, release ID, image, chart, manifest, pending migrations, and Session hard-cut setting.

1. Start Comma Deployment normally. No issue ID or comment ID is required.
2. Open the issue link from the workflow log or Slack notice.
3. Check the shutdown reason, durable facts, disposable scope, required backup evidence, and recovery procedure in the linked change.
4. A human with repository write, maintain, or admin permission posts a standalone approval comment.

Accepted replies include `yes`, `ok`, `okay`, `lgtm`, `approved`, `go ahead`, `同意`, and `批准`.
Case, surrounding whitespace, and a final period or exclamation mark do not matter.
Questions, conditional replies, quoted text, edited comments, and bot accounts do not approve.
Agents must not post, edit, or impersonate approval, including through a human account or token.
GitHub cannot tell a human from an agent that uses the human's credentials, so this prohibition stays necessary.

The executor waits at most 10 minutes, before the shutdown budget starts. It checks only the issue for this release.
Closing the issue, editing its generated title or body, an API failure, comment overflow, or timeout stops deployment before shutdown.
A later invocation creates a new issue. Old comments cannot approve another invocation or candidate.
Issue creation is not retried after an uncertain API response. The issue stays as an audit record.
Do not bypass the executor with manual scale, shutdown, or Helm maintenance commands without the same human approval.

### Slack approval notice

Slack replies do not approve a release.

Recovery can restore the captured pre-cutover snapshot, or keep incompatible old writers stopped after cutover, without a new approval.
An expired request does not authorize a new shutdown. Re-entry before cutover creates a new request.

## State and manifest

Active release state is schema V4 only.
V1 through V3, missing or unknown schemas, unknown fields, and retired phases fail closed before mutation.
The migration plan and manifest stay V2. Candidate bundles and environment specs stay V1. These versions are independent.

A V3-to-V4 transition requires a terminal `succeeded` or `recovered` state, no active runner, and the exact recorded positive deployed Helm revision.
An approved one-time operation changes only `schemaVersion` under a `resourceVersion` fence.
Record the preconditions. Verify the exact new body, V4 status, and V3 rejection before further mutation.
After any V4 release mutation starts, do not restore V3 or run a V3 binary.
Fresh environments create V4 directly. Normal commands never convert old state.

The manifest is `systems/apps/comma/priv/release/migration-manifest-v2.json`.
`stepDefaults` expands before validation, digest, planning, or execution.
The complete plan carries digest, required mode, exact pending IDs, phases, compatibility, budgets, postconditions, and named repairs unchanged to the executor.
Do not infer authority from migration filenames, version cutoffs, globs, SQL, or a V1 projection.
Missing IDs, checksum drift, unknown fields, invalid order, and missing safety facts fail planning.
Provider work stays outside the manifest.

## Adding or repairing a migration

Every PostgreSQL or ClickHouse migration enters the manifest in the same change.
Choose `expand`, `contract`, `exclusive`, or `local_seed`.
Declare owner, exact source, version and checksum, compatibility, idempotency, transactionality, timeout and lock budgets, destructiveness, backup need, rollback, postconditions, and repair.
Nontransactional steps need idempotent repair and explicit schema postconditions.
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
For Staging `applying`, dispatch `Comma Forward Repair` from `main` with the recorded release ID. It checks the phase and runs the remaining steps with the recorded artifacts.

## Hard budgets

These budgets cover the Comma release coordinator. The Gateway Container image release uses one 75-minute Group drain budget. See the [Gateway release procedure](../systems/cloudflare/salix-vm-gateway/RELEASE.md).

| Operation | Staging | Production | Approval/response |
| --- | --- | --- | --- |
| Rollout and convergence | 20 minutes | 20 minutes | Platform release operator and on-call |
| Writer-fenced cutover | 10 minutes | 5 minutes | Data/Runtime approval, Platform operation, both respond |
| Migration repair before escalation | 20 minutes | 10 minutes | Manifest owner and Data/Runtime on-call |
| Provider convergence | 30 minutes | 15 minutes | BFT provider on-call |

A cutover budget bounds completion, not uninterrupted availability.
On expiry, stop promotion, keep the safe fenced Helm revision, and page Platform and Data/Runtime.

## Provider and Agent convergence

Core success does not depend on provider convergence.
While providers are pending or failed, serve the existing configuration and reject provider-changing admin operations as temporarily unavailable.
Do not roll back the application or database after core success for this condition.

Budget exhaustion sets `provider_degraded`, pages provider on-call, and keeps core `succeeded`.
A later reconcile resumes from durable facts in a fresh bounded window. No background observer runs without a bound.

After core and provider success and old-writer exit, the serving RPC transfers Agent configuration, then Group Compute.
Group transactions copy up to 20 objects and the cursor. Sources stay intact.
The same handoff converts known legacy Cloudflare Group locations and pending start claims from old writers, up to 100 rows per page. Unknown locations stay for exact repair.
Then it closes the station roster window, and moves the Cloud VM switch onto Groups: Salix's pass over Agent records, then Comma Workspaces', then BFT Projects', up to 100 each per page.
The marker `group_cloud_vm_switch_v1` records the next of these pages, so a run cut off resumes there and a run after the last does nothing.
A Workspace whose switch Salix refuses for good is logged and passed; any other error stops the page for a retry.
Agent admission gates mutations. Group admission gates reads and writes until the last page.
Budget: staging 10 minutes, production 5 minutes.
Failure exits nonzero and core stays `succeeded`. Repair, then run `comma-release finish-agent-configuration`.
After admission, keep old writers stopped. Group repair is forward-only. Agent rollback stays fence-aware.
The local empty-store bootstrap is not a hosted repair path.

## Secrets and packaged files

`comma-release` owns immutable content-addressed candidate Kubernetes Secrets, their references, and bounded garbage collection.
Helm owns stable workload references and non-secret checksums, not Secret payloads.
Gateway operations owns TLS inputs and the stable Gateway reference. Comma release materializes the selected TLS candidate.
Never put payloads in Helm values or history, rendered manifests, release state, logs, ConfigMaps, or chart artifacts.

VMM gateway secrets have their own owner under `k8s/salix-vmm-gateway/`.
The pinned Helm client and archive checksums live in the release tooling. Do not install `latest`.

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
