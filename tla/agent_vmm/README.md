# Agent VMM trust TLA+ model

`PersonalMeshTrust.tla` models device-signed mesh genesis, manager-issued
single-use invitations, PAKE key confirmation, transcript-bound encrypted
identity/permission proposal, ordered manager/joiner confirmation, abort cleanup,
registry CAS revisions, A to B to C membership convergence, replica freshness,
concurrent/offline revocation, and remove-wins tombstones. It also models
personal route requests and durable lost-result responses.

- Offline revocation is a fail-closed local deny, a retryable signed registry
  CAS, and receipt application. Loss is a stuttering step. Duplicate delivery
  reuses the operation ID and cannot advance the registry revision twice.
- Every initial route issue and retry rechecks current membership and local deny.
- Safety does not depend on progress or clocks.

Configurations:

- `PersonalMeshTrust_Safety`: safety invariants.
- `PersonalMeshTrust_Liveness`: turns off revocation churn and assumes weak
  fairness for invite, join, snapshot sync, and stale-replica expiry. A fully
  joined mesh then converges to the same full membership at every active device.
- `PersonalMeshTrust_RevokeLiveness`: a pending revoke drains under weak
  fairness for registry commit and local receipt application.
- `PersonalMeshTrust_UnsafeRejoin`: lets a tombstoned identity rejoin. Must
  violate `TombstonesDurable`.
- `PersonalMeshTrust_UnsafePairingBypass`: accepts the proposal before PAKE key
  confirmation. Must violate `PairingPayloadConfidential`.
- `PersonalMeshTrust_UnsafeRouteReplay`: treats a stored response as an
  authorization cache. Must violate `RouteAuthorizationCurrent` after revoke.

Implementation anchors:

- Agent VMM: `api/trust/v1/trust.proto`, `internal/host/trust`,
  `internal/host/operator_trust_darwin.go`,
  `internal/host/mesh_control_darwin.go`, `internal/host/store/mesh_route.go`,
  `apps/macos/AgentVMM/Features/MyDevices/MyDevicesView.swift`, and
  `internal/remoteconnector/registry.go`. `ListPersonalMeshes` is a bounded
  read of the modeled snapshot and adds no transition.
- Salix: PersonalMeshRegistry operation CAS and signed freshness receipt.
- Product: Agent VMM.app join/revoke confirmation state machine.

Run with `make tla` from the Comma repository root.
