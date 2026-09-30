# Agent VMM trust TLA+ model

`PersonalMeshTrust.tla` models device-signed mesh genesis, manager-issued
single-use invitations, PAKE key confirmation, transcript-bound encrypted
identity/permission proposal, ordered manager/joiner confirmation, abort cleanup,
registry CAS revisions, A→B→C membership convergence,
replica freshness, concurrent/offline revocation, and remove-wins tombstones.
Offline revocation is split into a fail-closed local deny, retryable signed
registry CAS, and receipt application. Loss is a stuttering step; duplicate
delivery reuses the operation ID and cannot advance the registry revision
twice. `PersonalMeshTrust_RevokeLiveness.cfg` checks that a pending revoke
drains under weak fairness for registry commit and local receipt application.
`PersonalMeshTrust_UnsafePairingBypass.cfg` deliberately accepts the proposal
before PAKE key confirmation and must violate `PairingPayloadConfidential`.
Personal route requests and durable lost-result responses are also modeled:
every initial issue and retry rechecks current membership and local deny. The
`UnsafeRouteReplay` configuration deliberately treats a stored response as an
authorization cache and must violate `RouteAuthorizationCurrent` after revoke.

Safety does not depend on progress or clocks. The liveness configuration turns
off revocation churn and assumes weak fairness for invite, join, snapshot sync,
and stale-replica expiry; under those assumptions a fully joined mesh converges
to the same full membership at every active device. The expected-counterexample
configuration permits a tombstoned identity to rejoin and must violate
`RemoveWins`.

Implementation anchors:

- Agent VMM: `api/trust/v1/trust.proto`, `internal/host/trust`,
  `internal/host/operator_trust_darwin.go`,
  `internal/host/mesh_control_darwin.go`, `internal/host/store/mesh_route.go`,
  `apps/macos/AgentVMM/Features/MyDevices/MyDevicesView.swift`, and
  `internal/remoteconnector/registry.go`. `ListPersonalMeshes` is a bounded
  read of the modeled snapshot and introduces no transition.
- Salix: PersonalMeshRegistry operation CAS and signed freshness receipt.
- Product: Agent VMM.app join/revoke confirmation state machine.

Run with `make tla` from the Comma repository root.
