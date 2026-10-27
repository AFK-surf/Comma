# Connector recovery after a retired server owner

Cluster updates follow the [rollout policy](../../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).
Temporary service failures are acceptable during rolling updates. Full recovery must meet the documented convergence budgets.

## Prevention and limits

During a graceful pod `preStop`, Comma withdraws readiness, drains actors, then closes local connector sockets.
`SalixWeb.ConnectorDrain` waits for each exact local owner process to stop before it marks the run disconnected and confirms its predecessor stop target.
The run and generation fence keeps concurrent successors. The connector drain has a deadline.
An upgrade that reaches socket initialization after the drain starts is rejected.
The lifecycle `connector_drain_complete` event reports completion or failure.

A crash, forced deletion, failed persistence, or exhausted shutdown deadline can still leave a stop target without proof.
A node missing from discovery or a disconnected device record **does not prove that its socket process stopped**.
These cases need independent operator evidence. No server timeout forgives an unreachable owner.

The desktop client revokes the credentials it no longer uses: a renewed one after it expires, a refused one before it mints the next one, and all of them at sign-out.
A failed `DELETE /v1/comma/workspaces/:id/connector-token` does not block the client. The credential's own lifetime bounds it.
The server keeps the pending stop target and the token record for that generation.
A failed revocation does not confirm the owner stop.

## Recover an already-stranded generation credential

This is a trusted operator mutation through release RPC, **not a public API**.
Do not run it as part of diagnosis or deploy it without the normal release authorization. Production execution belongs to a human operator.

Use this procedure to remove a stranded token record and its pending stop target.
A desktop client whose expired credential was refused does not need it. That client mints again by itself.

1. Read the pending generation from the device's `pending_connector_revocations`.
2. Find the token record under `ctl/connector_tokens/` whose `device_id` and `credential_generation` match it.
   Use the token's SHA-256 object name, not the raw bearer token. The desktop does not keep the raw token of a refused credential after it mints a replacement.
3. Verify tenant, group, device, connector id, and credential generation.
   Do not dump credentials or unrelated device metadata into logs.
4. Verify that the old server instances terminated, with their pod or container identity and termination evidence.
   A missing Pod object, a forced deletion, a readiness failure, or a network partition alone is not enough.
   If you cannot prove termination, restore reachability or have an authorized operator terminate the old instance first.
5. Pass only the verified terminated server node names in `dead_nodes`:

   ```elixir
   SalixEnv.ConnectorTokens.recover_connector_token(
     token_hash, device_id, group_id, tenant_id,
     dead_nodes: verified_terminated_nodes
   )
   ```

6. Verify the device's `pending_connector_revocations` for the exact generation. Do not claim recovery from RPC success alone.

The operation checks exact scope, advances the credential revocation fence, and confirms only this credential's owner targets.
Reachable members must confirm their own socket stops, even if they are in `dead_nodes`.
A failure keeps the token as the retry handle.
Success proves that the token was removed. It keeps the stable device, successor credentials, and the pending stops of other generations.
A repeat of a successful operation returns `{:ok, :already_revoked}`. It does not start a connector.
A connected desktop is not evidence that the pending stop was cleared, because the client has usually minted a new credential already.
Pre-generation device retirement is a separate operation.
