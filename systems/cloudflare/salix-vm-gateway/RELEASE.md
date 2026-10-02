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

The first control-protocol upgrade changes the Connector image and Gateway together.
It uses `sandbox_image`, which skips the Worker-only candidate path.
New Salix drains legacy full archives through the serving old Gateway before the full image deploy.
Do not publish this Gateway first as a Worker-only upgrade. Old targets cannot prove the new command seal.

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
matches Container instances to persisted Group Workload resources in their exact profile.
Only instances with a business association enter the archive and stop checks.
Containers without a business association are disposable during image replacement.
The job ignores them, regardless of their name or state.
It does not wait for their archive or shutdown.
It stops for an unsettled Group Gateway start claim, a running or unknown business instance,
an incomplete page, or a storage error. Inactive Durable Object rows can remain.

WebSocket attempts retain their exact Sandbox and profile before connection.
A refused TCP connection, failed DNS lookup, or definitive handshake rejection settles that attempt.
An uncertain handshake retains one `pending_start` claim per Sandbox and profile.
A successful connection or ready response settles pending starts from the same owner control revision.
The carrier retains only its latest terminal command. Salix settles that exact claim before a retry can replace the receipt.
A later command can replace a concurrent lost-response receipt. The existing seal path settles covered managed claims, or the operator repairs them exactly.
Active requests retain their claims. The Workload supplies a fixed operation permit, independent of activity revisions.
The Sandbox DO stores its seal and pending native command across restarts.
Control and receipt observations never start a stopped Container. Managed commands bypass SDK auto-start retries.
An exact restored import receipt can settle its pending import. An unresolved command keeps its claim.
A sealed DO with no pending command settles only qualified claims for that exact location and generation.
Claims have no age-based expiry. Storage failure or abrupt process loss can still require exact operator repair.
Historical active claims without a target require operator repair. A current ready response cannot identify their original target.

Salix records each archive's storage in the Group Workload before it destroys a Sandbox.
New Connectors use R2. Older Connectors can use Salix S3.
The job does not survey unrelated services.
Stopped business Container rows require one exact Group owner with a recorded archive.
Both profiles share one 75-minute drain deadline from the release fence. Retrying the same release preserves that deadline.
A new release can take over with its own deadline. This does not reset an existing restore operation's budget.
This is a wait
budget, not an ownership lease. Read the exact Group and operation through
`GET /v1/admin/vm/archive/operation?group_id=...&operation=...` to see packed
and confirmed uploaded bytes. `packed_at` is the Connector's last pack write;
`reported_at` is the Salix observation time. Before commit, an administrator can request
`POST /v1/admin/vm/archive/cancel` with that Group and operation. Salix clears
the operation only after the Connector stops and the runtime resumes. A failed
or unknown cancel leaves the Workload in `archiving` for repair.
An archive in `idle_committing` or `recovery_committing` cannot be cancelled because Container release may have begun.
The owner resumes a committed archive without exporting again or replacing its previous generation.
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
not a security signature. The job disables each probe's keepAlive and requests destruction.
Probe cleanup is best-effort. The job does not wait for shutdown or block image release on cleanup failure.
It records the verified source revision in Salix and clears the exact release fence.
Connector payload verification still blocks release when the fresh probe serves the wrong revision.

For a new release, a failure before `deploying` cancels only the matching `prepared` fence.
It preserves any still-active direct Gateway claim. A failure after `deploying`
leaves the fence in place. Rerun the failed job in the same Comma Deployment run: it repeats
the business drain check and full deploy. Unassociated instances from any run do not block that check.
The job then checks the active Worker and the exact Connector payload in fresh probes for both profiles. It records the image digest and clears
the fence. If those checks
fail, keep the fence and investigate the affected application before a
forward repair from the same approved mainline source. Do not infer success
from Worker `/healthz`, the release fact, or the image build alone.
If a newer Comma release succeeds before that retry, its image job takes over
the existing fence. It still runs the bounded drain check and full deploy before
it clears that fence. The older run can no longer clear it.

The operator investigates only the affected Group Workloads, their claims, and their associated instances.
Cloudflare reconciliation tasks use the 55-minute provider claim lease, with 30 seconds reserved for settlement.
A wake's restore retries share its original 45-minute deadline. An expired deadline prevents more restore writes.
A requested reconciliation first confirms an exact connected wake before it checks the budget.
The sweep still parks action-required claims. An exact owner reconciliation can confirm their completed wakes.
A restored import receipt can also confirm completion after its transfer deadline. It does not authorize target deletion.
A partial import preserves its target and retained archive. A `restoring` receipt does not authorize target deletion.
Neither a missing connection nor a matching wake ID proves that accepted work has settled.
For a managed `waking` target, Salix seals carrier commands and Connector admission before it selects a recovery path.
A successful quiet seal can report that the target never admitted business work.
That fact requires the image's consumed birth marker, an initially absent runtime state, and persistent admission history.
An old or empty disk alone does not prove it. Salix also verifies every retained source archive chunk before deletion.
An admitted or unknown target requires a quiet recovery checkpoint before deletion.
Recovery retains native continuation, credentials, runtime identity, and unknown files outside the approved disposable paths.
It omits Agent workspaces, managed dependency packages, and workspace sweep archives.
It preserves original Salix Sessions and accepted queues. It does not replay actions with unknown outcomes.
The restored Agent receives a recovery notice and must rebuild omitted workspace contents.
Salix retains the previous archive for recovery. This implementation does not collect that held generation automatically.
After confirmed destruction, the Workload keeps `waking`, its wake ID, and `archive_reason=recovery_rebuild`.
The release fence blocks its next start until image publication completes.
The next owner permit advances the control revision and starts one persisted restore-stage budget.
Legacy targets retain the existing full archive path. They cannot supply new admission or recovery proofs.
Unknown commands, unresolved work, missing continuation, or unavailable critical credentials require exact repair.
An existing archive, a disconnected Device, or elapsed time alone cannot authorize deletion.
The release can replace an unassociated Container disk without an archive.
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
