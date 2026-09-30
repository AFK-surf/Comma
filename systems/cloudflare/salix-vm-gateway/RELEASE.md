# Salix VM Gateway Release

Worker-only releases use per-VM rollout. A full `wrangler deploy` can replace
Container disks. Comma Deployment publishes a Container image only after its
selected mainline Salix release succeeds and the final drain check passes.
An operator starts Comma Deployment. Its Gateway image job runs automatically
after the Comma release succeeds. Use the image workflow's manual entry only to
repair an interrupted mainline release.

## Gateway-Only Candidate

CI publishes Worker-only candidates for pushes to `main`/`prod` and manual
`workflow_dispatch` runs in `.github/workflows/salix-vm-gateway.yml`. The CI job
builds the connector image payload, uploads a Worker version with explicit
`GATEWAY_BUILD_ID` and `CONNECTOR_IMAGE_VERSION`, attaches that candidate to the
active deployment at 0%, and verifies `/healthz` through
`Cloudflare-Workers-Version-Overrides`. After the smoke passes, CI writes that
candidate version to Salix `/v1/admin/vm/worker-release` as
`desired_worker_version_id`.

The image version is the active Worker's label; it does not prove which image
each running Container uses. CI does not publish a new Container image, promote
the candidate to 100%, or force-switch VMs. Salix owns the per-VM rollout.
Connector changes on `main`/`prod` run checks without publishing an image.
Comma Deployment uses the revision embedded in its selected immutable Comma image.
It skips a repeat Container deploy when the tracked Container runtime sources
have not changed since the recorded image revision. The recorded revision
remains the actual source of that image. A change to Comma outside those sources
does not require a new disk archive. Worker source, package, and TypeScript
changes do not change the Container image; they use the Worker candidate path.
Image build recipe changes must update a tracked script or Dockerfile. The
recorded digest is release history. The job stops if it cannot compare the
mainline runtime sources.

## Container Image Release

Before the first dual-profile Gateway release, the Salix mainline migration
sets known legacy Group locations to standard-2 and qualifies saved pending
Gateway start claims. Until that release is deployed, the Gateway answers 404
for the standard-1 sandbox collection. Salix then marks a new standard-1 Group
VM `failed` with the error `cloud-vm Gateway does not serve Container profile`
after one request, and the next use of that VM restarts provisioning. The post-rollout handoff repeats this bounded conversion
after old writers exit. An unknown location stays unresolved and blocks the drain.
When tracked Container runtime sources change, the job sets an
ID-scoped release fence. Managed Gateway attempts
and the standalone preflight probe use that fence and keep a claim when the
provider result is uncertain. The job pages the affected Gateway Group
Workloads and reads every page of each affected Cloudflare Container
application and instance inventory. The first release can have only the existing
standard-2 application before deploy. The pinned Wrangler JSON commands return
only one page, so the release adapter follows Cloudflare's page token. It
asks Salix to archive and stop each running Container with an exact Group
Workload owner in its exact profile. It then stops for an unsettled Gateway start claim, a running
or unknown Container instance, an incomplete page, or a storage error.
Inactive Durable Object rows can remain. Salix records each archive's storage
in the Group Workload before it destroys a Sandbox. New Connectors use R2;
older Connectors can use Salix S3. The job does not survey unrelated services.
Stopped Container rows require one exact Group owner with a recorded archive.
The job waits at most 75 minutes for an unfinished archive. This is a wait
budget, not an ownership lease. Read the exact Group and operation through
`GET /v1/admin/vm/archive/operation?group_id=...&operation=...` to see packed
and confirmed uploaded bytes. `packed_at` is the Connector's last pack write;
`reported_at` is the Salix observation time. Before commit, an administrator can request
`POST /v1/admin/vm/archive/cancel` with that Group and operation. Salix clears
the operation only after the Connector stops and the runtime resumes. A failed
or unknown cancel leaves the Workload in `archiving` for repair. An archive in
`idle_committing` cannot be cancelled because Container release may have begun.
This cancel path requires an updated Connector. An older Connector that rejects
DELETE needs exact, operator-led recovery; the new API cannot stop its worker.

An archive repair connection accepts existing Runtime events through normal
capability validation and per-event acknowledgement. This lets the Connector
settle retained output and reconnect observations before quiet. The connection
rejects tool requests, input catch-up, and other Connector-originated requests.

The drain step checks unsettled Gateway starts and the final instance inventory
before it returns. The job then records `deploying` before `wrangler deploy`. It
checks the active Worker version and starts one fresh, disposable Sandbox in each
profile for up to 15 minutes. Each probe reads the source
revision baked into the Connector binary through `/readyz`; a Worker label
alone cannot prove the Container payload. This revision is release provenance,
not a security signature. The job destroys each probe and confirms it stopped in
its exact application. It records the verified
source revision in Salix, and clears the exact release fence.

For a new release, a failure before `deploying` cancels only the matching `prepared` fence.
It preserves any still-active direct Gateway claim. A failure after `deploying`
leaves the fence in place. Rerun the failed job in the same Comma Deployment run: it repeats
the drain check and full deploy. If that run left one of its own probes active,
the drain destroys it in its exact application and confirms it stopped before
checking Group Workloads. Historical probes require operator review. The job then checks the active Worker and the exact
Connector payload in fresh probes for both profiles. It records the image digest and clears
the fence. If those checks
fail, keep the fence and investigate the affected application before a
forward repair from the same approved mainline source. Do not infer success
from Worker `/healthz`, the release fact, or the image build alone.
If a newer Comma release succeeds before that retry, its image job takes over
the existing fence. It still runs the bounded drain check and full deploy before
it clears that fence. The older run can no longer clear it.

The operator investigates only the affected Group Workloads, their claims,
and their applications' instances. Old probes without a known release owner need
operator review; the job does not destroy them by name. An active disk must be archived before
replacement unless its owner explicitly approves disposal.
Ask the owner only for a specific data-loss choice or the documented shutdown
or `exclusive` approval. Normal implementation and a passing drain check do
not require another user decision.

## Durable Object Lifecycle Migrations

`wrangler versions upload` cannot perform Durable Object lifecycle migrations
or publish a Container image. These changes require the full image release
above. The same drain check applies to any manual repair deploy. A dry run and a
Worker `/healthz` response do not establish disk safety.

## Salix controls

Salix selects the desired Worker version for each VM. Use the
[Cloud VM operations skill](../../../.codex/skills/cf-vm-ops/SKILL.md) for
per-VM rollout, rollback, and exact Group status. A default-provider change
affects future VM creation only. Existing Group providers remain persisted.
For state, leak, and archive diagnostics, use the
[Cloud VM operations reference](../../DEPLOYMENT.md#operations).
