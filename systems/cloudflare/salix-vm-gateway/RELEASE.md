# Salix VM Gateway retirement

CF Sandbox publishing is retired. The repository keeps the implementation and its directory-scoped PR checks.
There is no automatic or manual Gateway publishing workflow. Comma Deployment has no CF image job or drain gate.

## Container Image Release

Do not publish another CF Container image for retirement.
Both hosted environment specs set `l4es.cloudVmRetired` to true.
Production takes that setting through the normal promotion of staging-proven mainline code to `prod`.
The post-rollout [Cloud VM cutover](../../../docs/agent-runtime.md#cloud-vm-cutover) changes Group defaults and Worker bindings.
It closes old CF Tasks with a notice and requests Workload stops.
It preserves Messages, Sessions, execution records, billing facts, and Agent VMM Host workloads.

The release does not wait for CF provider operations.
Keep the transport credentials while existing Workloads need teardown.
A completed cutover marker does not prove that the provider stopped.
Read its `failed` count and the exact Workload state separately.
Unknown operation results remain unknown. Do not replay old execution on a replacement machine.

## Salix controls

The Workload owner performs background teardown with the existing bounded retry budget.
Use the [operations reference](../../DEPLOYMENT.md#operations) for exact Workload and operation reads.
Use [Cloud VM operations](../../../.codex/skills/cf-vm-ops/SKILL.md) for a failed teardown.
After the exact resources stop, remove their Worker, Container applications, DO namespaces, routes, and dedicated credentials.
Keep unrelated Cloudflare services and Agent VMM Gateways.
Existing archives follow the retention period in the cutover contract.

## Restore before start: release order

There is no new restore or image rollout during retirement.
Do not wake an archived VM to verify or preserve it.
Existing recovery retains its owner, fencing, and unknown-effect rules.
Cloudflare Group disks follow the [Cloud VM data policy](../../../docs/compute-devices.md#cloud-vm-data-policy).
