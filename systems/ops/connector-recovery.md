# Connector recovery after a retired server owner

Cluster updates follow the [rollout policy](../../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).
Temporary service failures are acceptable during rolling updates. Full recovery must meet the documented convergence budgets.

## Prevention and limits

During a graceful pod `preStop`, Comma withdraws readiness, drains actors, then
closes local connector sockets. `SalixWeb.ConnectorDrain` waits for each exact
local owner process to terminate before marking its run disconnected and
confirming its predecessor stop target. Concurrent successors are preserved by
the run/generation fence. The entire connector drain has a 15-second deadline.
An in-flight upgrade reaching socket initialization after drain begins is
rejected. This does not lengthen credentials or weaken revocation.

The existing lifecycle `connector_drain_complete` event reports completion or
failure. Socket-down logs include a bounded reason (expiry, revocation, drain,
heartbeat timeout, replacement, normal, or other), not arbitrary frame/error
contents. HTTP latency/error metrics continue to cover the revoke endpoint.

A crash, forced deletion, failed persistence, or exhausted shutdown deadline
can still leave a stop target without proof. A node missing from discovery or
a disconnected device record **does not prove its socket process stopped**.
Those cases intentionally require independent operator evidence; no server
timeout automatically forgives an unreachable owner.

The desktop client bounds its own revoke-before-mint retry by the credential
lifetime. When the requested TTL has elapsed and the server has refused the
credential to the connector, two failed `DELETE /v1/comma/workspaces/:id/connector-token`
attempts no longer block the client. It mints a replacement and reconnects.
The server keeps the pending stop target and the expired token record for that
generation. This bound does not confirm the owner stop, and it does not apply
to a credential inside its TTL.

## Recover an already-stranded generation credential

This is a trusted operator mutation through release RPC, **not a public API**.
Do not run it as part of diagnosis or deploy it without the normal release
authorization. Production execution belongs to a human operator.

Use this procedure to remove a stranded token record and its pending stop
target. It is not required to restore a desktop client whose expired
credential was refused: that client re-mints on its own.

1. Match the affected client's workspace/device and credential to its stored
   token record. Use the token's SHA-256 object name, not the raw bearer token.
   Verify tenant, group, device, connector id and credential generation. Do not
   dump credentials or unrelated device metadata into logs. The desktop does
   not keep the raw token of an expired, refused credential after it mints a
   replacement. Read the pending generation from the device's
   `pending_connector_revocations`. Find the token record under
   `ctl/connector_tokens/` whose `device_id` and `credential_generation` match it.
2. Inspect that device's `pending_connector_revocations` for the exact generation.
   Independently verify the old server instances have actually terminated, using
   their pod/container identity and termination evidence. A missing Pod object,
   a forced deletion, a readiness failure, or a network partition alone is not
   sufficient. If termination cannot be established, restore reachability or
   have an authorized operator terminate the old instance first.
3. Pass only the verified terminated server node names in `dead_nodes`:

   ```elixir
   SalixEnv.ConnectorTokens.recover_connector_token(
     token_hash, device_id, group_id, tenant_id,
     dead_nodes: verified_terminated_nodes
   )
   ```

The operation checks exact scope, advances the credential revocation fence,
and confirms only this credential's owner targets. Reachable members must
confirm their own socket stops even if included in `dead_nodes`. A failure
retains the token as the retry handle. Success proves that token was removed;
it preserves the stable device, successor credentials and other generations'
pending stops. Repeating a successful operation returns `{:ok, :already_revoked}`.
It does not start a connector. A client with a live credential retries the
revocation, then mints. A client whose credential had expired and was refused
has usually re-minted already, so a connected desktop is not evidence that the
pending stop was cleared: verify the device's `pending_connector_revocations`
for the exact generation. Do not claim recovery based on RPC success alone.
Pre-generation device retirement remains a separate operation.

## Verification scope

Regressions cover real WebSocket drain/reconnect, reply-before-process-exit,
a racing successor, an uncooperative owner, late socket admission, scoped
operator recovery, and the desktop's expired-credential re-mint
(`clients/apps/electron/e2e/connector-runtime-containment.spec.ts`). The
connector feature models were retired under
[`tla/README.md`](../../tla/README.md); these changes do not add a new model or
change the retained system-core lease/ACK/stream contracts. In particular,
partition uncertainty and the need for positive stop evidence remain intact.
