# Salix VM Gateway Release

Worker-only releases use per-VM rollout. A full `wrangler deploy` can replace Container disks.
An operator starts Comma Deployment. Its Gateway image job runs automatically after the selected mainline Salix release succeeds.
The job publishes a Container image only after the final drain check passes.
Use the image workflow's manual entry only to repair an interrupted mainline release.

## Gateway-Only Candidate

CI publishes Worker-only candidates for pushes to `main` or `prod` and for manual `workflow_dispatch` runs of `.github/workflows/salix-vm-gateway.yml`. The job:

1. Builds the connector image payload.
2. Uploads a Worker version with explicit `GATEWAY_BUILD_ID` and `CONNECTOR_IMAGE_VERSION`.
3. Attaches that candidate to the active deployment at 0%.
4. Verifies `/healthz` through `Cloudflare-Workers-Version-Overrides`.
5. Writes the candidate to Salix `/v1/admin/vm/worker-release` as `desired_worker_version_id`.

The image version is the active Worker's label. It does not prove which image each running Container uses.
CI does not publish a new Container image, promote the candidate to 100%, or force-switch VMs. Salix owns the per-VM rollout.
Station changes on `main` or `prod` run checks without publishing an image.

Comma Deployment uses the revision embedded in its selected immutable Comma image.
It skips a Container deploy when the tracked Container runtime sources have not changed since the recorded image revision.
A Comma change outside those sources does not need a new disk archive.
Worker source, package, and TypeScript changes do not change the Container image. They use the Worker candidate path.
Image build recipe changes must update a tracked script or Dockerfile.
The job stops if it cannot compare the mainline runtime sources.

## Container Image Release

Cloudflare Group disks follow the [Cloud VM data policy](../../../docs/compute-devices.md#cloud-vm-data-policy).
Try bounded recovery. If it fails, the owner may destroy and rebuild the exact VM without another disk-loss approval.
Keep central Salix data, command fencing, and unknown execution outcomes under their owners.
Do not restore old pending execution after a destructive reset.

A terminal export failure or an expired restore budget lets the image-release worker request exact owner disposal:

- The worker keeps the release fence and checks the Workload, generation, resource, profile, and operation before disposal.
  A quiet check, an unknown provider result, or a changed owner does not use this path.
- The owner seals a higher control revision and destroys the exact carrier.
  An unresolved native destroy stays pending. A lost response needs an observation of the same completed destroy.
- Only that receipt advances the Workload generation and removes the current restore pointer. Usable previous archives stay stored.
- The worker resumes a persisted disposal after process loss. Final drain accepts its exact completed stop receipt without a disk archive.
- Central unknown input stays unresolved and cannot resume automatically on the empty disk.

For this Worker-only protocol change, wait for the selected mainline Worker candidate and Comma image before deployment.
Finish the Comma rollout before disposal. The image-release worker uses the published candidate through the version override.
Do not restore a pre-generation-admission Comma binary after a reset. Use forward repair that keeps the admission checks.

The first control-protocol upgrade changes the Connector image and Gateway together.
It uses `sandbox_image`, which skips the Worker-only candidate path.
New Salix drains legacy full archives through the serving old Gateway before the full image deploy.
Do not publish this Gateway first as a Worker-only upgrade. Old targets cannot prove the new command seal.

Before the first dual-profile Gateway release, the Salix mainline migration sets known legacy Group locations to standard-2 and qualifies saved pending Gateway start claims.
Until that release is deployed, the Gateway returns 404 for the standard-1 sandbox collection.
Salix then marks a new standard-1 Group VM `failed` with `cloud-vm Gateway does not serve Container profile` after one request. The next use of that VM provisions it again.
The post-rollout handoff repeats this bounded conversion after old writers exit. An unknown location stays unresolved and blocks the drain.

When tracked Container runtime sources change, the job sets an ID-scoped release fence.
Managed Gateway attempts and the standalone preflight probe use that fence and keep a claim when the provider result is uncertain.
The job pages the affected Gateway Group Workloads and reads every page of each affected Cloudflare Container application and instance inventory.
It matches Container instances to persisted Group Workload resources in their exact profile.
Only instances with a business association enter the archive and stop checks.
Containers without a business association are disposable during image replacement. The job ignores them, whatever their name or state.
The job stops for an unsettled Group Gateway start claim, a running or unknown business instance, an incomplete page, or a storage error.

A start request keeps its exact Sandbox and profile. The one native start completes it. The Container's station then connects out to Salix by itself.
A wake's start names the archive to restore (`station.restore`). The value holds one R2 read URL, signed for one hour, of the archive's `restore-manifest` object.
Salix writes that object at each wake, next to the parts. The manifest lists each part's read URL, signed for the same hour. Archive cleanup deletes it with the parts.
The Container gets the value as `SALIX_RESTORE_ARCHIVE`. Its entrypoint unpacks the archive onto the empty disk in the station's data directory, then starts the station.
A Container that cannot restore exits with code 65 and starts no station. Salix reads that stop in `last_stop` and starts another Container inside the restore budget.

Gateway start claims:

- An uncertain response keeps one `pending_start` claim per Sandbox and profile. A later completed start or running status from the same owner control revision settles it.
- The carrier keeps only its latest terminal command. Salix settles that exact claim before a retry can replace the receipt.
- A later command can replace a concurrent lost-response receipt. The seal path settles covered managed claims, or the operator repairs them exactly.
- Active requests keep their claims. The Sandbox DO stores its seal and pending native command across restarts.
- Control and receipt observations never start a stopped Container. Managed commands bypass SDK auto-start retries. An unresolved command keeps its claim.
- A sealed DO with no pending command settles only qualified claims for that exact location and generation.
- Claims have no age-based expiry. Storage failure or abrupt process loss can still need exact operator repair.
- Historical active claims without a target need operator repair. A current ready response cannot identify their original target.

The archive path records storage in the Group Workload before destruction. Stations use R2.
Stopped business Container rows need one exact Group owner with a recorded archive or confirmed disposal receipt.
Both profiles share one 75-minute drain deadline from the release fence. A retry of the same release keeps that deadline.
A new release can take over with its own deadline. This does not reset an existing restore operation's budget.
This is a wait budget, not an ownership lease.

Read the exact Group and operation with `GET /v1/admin/vm/archive/operation?group_id=...&operation=...` to see packed and confirmed uploaded bytes.
`packed_at` is the station's last pack write. `reported_at` is the Salix observation time.
Before commit, an administrator can send `POST /v1/admin/vm/archive/cancel` with that Group and operation.
Salix clears the operation only after the station stops and resumes. A failed or unknown cancel leaves the Workload in `archiving` for repair.
An archive in `idle_committing` or `recovery_committing` cannot be cancelled, because Container release may have started.
The owner resumes a committed archive without exporting again or replacing its previous generation.

The drain step checks unsettled Gateway starts and the final instance inventory. The job then records `deploying` and runs `wrangler deploy`.
It checks the active Worker version and starts one fresh, disposable Sandbox in each profile.
A probe passes when its Container keeps running for a fixed time. The probe can start the same Sandbox again only after control observation confirms it stopped, is unsealed, and has no pending command.
The owner, operation, generation, and control revision must match the probe. Each retry uses a new command claim. Unknown starts keep their pending state.
Probe cleanup is best effort and does not block the image release.
After both probes pass, the job records the observed image digest and the source revision in Salix, then clears the exact release fence.
The digest is diagnostic provenance and can lag the provider rollout.

Failure handling:

- A failure before `deploying` cancels only the matching `prepared` fence. It keeps any active direct Gateway claim.
- A failure after `deploying` leaves the fence in place. Rerun the failed job in the same Comma Deployment run.
  It repeats the business drain check, full deploy, active Worker check, and fresh probes for both profiles, then records the digest and clears the fence.
- If those checks fail, keep the fence and investigate the affected application before a forward repair from the same approved mainline source.
  Do not infer success from Worker `/healthz`, the release fact, or the image build alone.
- If a newer Comma release succeeds before that retry, its image job takes over the fence. It still runs the drain check and full deploy before it clears the fence. The older run can no longer clear it.

The operator investigates only the affected Group Workloads, their claims, and their associated instances.
Automatic restore retries share one 45-minute deadline. An expired deadline parks the operation and stops more restore writes.

To open one new bounded restore episode, call `ComputeReconciler.retry_group_restore(group_id, expected)`:

1. Read the current Workload and claim.
2. Pass the exact Workload ID, generation, wake ID, restore deadline, target, profile, archive operation, control permit, and claim error.

The owner rejects changed facts, a live claim lease, and a sealed target. The same request cannot renew twice.
The call keeps the wake, archive, target, permit, queues, and Gateway claims. It does not clear a restore receipt.
A Container whose restore did not finish is replaced, never restored a second time.
`retry_runtime_recovery` does not renew a waking Group's restore budget.
A connected station's restore receipt can confirm completion after its transfer deadline. It does not authorize target deletion.
A restore runs only before a station starts. A running station accepts no archive.

A recovery archive can keep native continuation and opaque auth and configuration bytes without a harness launch.
Codex uses saved thread identity and rollout metadata. Pi uses `PI_CODING_AGENT_DIR`, or `~/.pi/agent` when unset.
A failed checkpoint does not revoke approved disk disposal.

To discard a failed VM, call `Cloudflare.discard_failed_vm(group_id, expected)` after the Comma rollout completes:

1. Pass a fresh exact Workload snapshot.
2. Confirm the exact carrier stopped before you replace it.

Do not clear receipts or claims through direct database edits. Unknown effects stay unresolved, even after local disk loss.
The release fence blocks replacement starts until image publication completes.
Deployment-wide shutdown and `exclusive` migration keep their documented human approval.

## Restore before start: release order

Salix, the Worker, and the image change together in one mainline revision.
Comma Deployment releases Salix first. The image job then releases the Worker and image. These combinations occur:

| Salix | Worker | Image | A wake of a VM that has an archive |
| --- | --- | --- | --- |
| new | old | old | The Worker drops `station.restore`. The station starts on an empty disk. Salix finds no restore receipt and fails the wake with `archive_not_restored_before_start`. |
| new | new (Worker-only candidate) | old | The image ignores `SALIX_RESTORE_ARCHIVE`. Same failure. |
| new | new | new | The wake completes on the restored disk. |
| old (rollback) | new | new | Old Salix asks the station for `archive_import`. The station refuses the unknown method and the wake fails. Do not roll Comma back after the image release. |

The failed wake stays `waking`, keeps `last_error` with the Worker's `connector_image_version` and `gateway_build_id`, and retries inside its 45-minute restore budget.
The image job's drain rebuilds or disposes of that target under its rules, and the next wake runs on the new image. A wake of a VM without an archive is the same in every combination.
Version labels do not decide this. The restore receipt on the disk does.

## Durable Object Lifecycle Migrations

`wrangler versions upload` cannot perform Durable Object lifecycle migrations or publish a Container image.
These changes need the full image release above. The same drain check applies to any manual repair deploy.
A dry run and a Worker `/healthz` response do not prove disk safety.

## Salix controls

Salix selects the desired Worker version for each VM.
Use the [Cloud VM operations skill](../../../.codex/skills/cf-vm-ops/SKILL.md) for per-VM rollout, rollback, and exact Group status.
A default-provider change affects future VM creation only. Existing Group providers stay persisted.
For state, leak, and archive diagnostics, use the [Cloud VM operations reference](../../DEPLOYMENT.md#operations).
