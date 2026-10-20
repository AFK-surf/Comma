# Salix integration evaluation adapter

## Purpose and boundary

This adapter materializes pre-authorized third-party capabilities into the fresh Salix
Agent group created for each Evalens dataset item. It evaluates Agent behavior through
real integrations. It does not replace Salix protocol or integration E2E tests.

Keep provider signature verification, OAuth callback exchange, refresh/revoke, webhook
retry, cursor recovery, and actor recovery in the owning Salix integration tests.

## Scope invariants

- Keep the adapter tenant-scoped. It must not accept administrator credentials,
  call `/v1/admin/*`, or expose global template/catalog management. Experiments
  receive a pre-provisioned tenant-visible `templateId` through configuration.
- Create a new Salix group and router before materializing any integration.
- A tenant selects the storage partition. It does not make an integration available to
  every Agent in that tenant.
- Slack IM connects are group-owned and bound to the new router.
- OAuth tokens may live in tenant-partitioned credential storage, but only the fresh
  group's OAuth/MCP binding gives an Agent access.
- Plugin and MCP definitions may be shared catalog state. Enablement and bindings that
  expose tools stay group-scoped.
- Datasets and run parameters must not contain integration secrets.

## Configuration contract

All Salix-bound credentials belong in `adapters.salix.integrations[]`. Experiments select
one entry by stable `id`. Experiments and datasets do not select Salix storage or
connection details.

The config distinguishes credential shape only:

- `credentials.type: app` carries provider installation credentials. Slack
  materializes it as a native IM connect bound to the fresh router Agent ID.
- `credentials.type: oauth` carries a pre-authorized OAuth grant and optional plugin
  connection.

Do not add `materializationKind` to Evalens configuration. Salix infers it:

- app credentials infer `im_connect`.
- OAuth without a plugin, or with a `managed_oauth` connection, infers `managed_oauth`.
- OAuth with a `native_mcp_oauth` connection infers `remote_mcp_oauth`.

Salix reads the connection kind from the plugin definition and validates provider,
alias, and required scopes before it persists a binding. The response may report the
inferred kind for parsing, cleanup, and diagnostics. It must never return credentials.

## Lifecycle and failure semantics

Use the unified endpoint:

```text
POST /v1/runtime/agent-groups/:group_id/eval/integration-materializations
```

- Materialization is idempotent for the same group and logical integration.
- A logical OAuth alias is claimed with compare-and-set ownership. A different
  integration must conflict. It must not reuse or overwrite the existing credential.
- Failed materialization compensates only the OAuth, MCP, and plugin state created by
  that request. Never snapshot and restore whole group prefixes. Another request may
  have committed valid state after the snapshot.
- Register cleanup discovery before you send an IM materialization request. This covers
  a server commit followed by a lost or malformed client response.
- Delete/discover IM connects before you delete Agents and the group.
- Cleanup attempts all phases and aggregates failures. It does not stop at the first
  error.
- Retry transient cleanup transport, throttling, and server failures within the single
  cleanup call. If IM cleanup still cannot be confirmed, keep the group so a later
  reconciliation can still reach the connect.
- Bound all waits. A timeout becomes an unsettled observation. It must not hang a run.
- Authentication, permission, materialization, SDK, and trajectory-collection failures
  are run errors.
- Delivered input followed by no provider-visible Agent result is an evaluable Agent
  failure.

One Slack app identity supports one active group connect. Keep Slack live evaluation
concurrency at `1` until Salix supports leased or multi-binding installations. A
permanent connect-cleanup failure can reserve the app. Report it as infrastructure
failure.

## Provider requirements and limitations

- Native IM materialization supports Slack only.
- GitHub, Google, and Linear normally use managed OAuth plugin connections.
- Notion uses a native remote-MCP OAuth connection.
- Pre-authorized capability scenarios must materialize valid credentials before the
  scored interaction. Missing-connection/link guidance is a separate dataset class.
- This materializer does not isolate external repositories, projects, pages,
  mailboxes, or calendars. The experiment owns deterministic external fixture setup.
- Group deletion removes Agent access, but OAuth/MCP eval credential records are not
  revoked or deleted. Do not revoke a shared source grant during ordinary item cleanup.

## Verification

After you change this adapter or its config/protocol contract, regenerate the config
schema and run from `devtools/evalens`:

```sh
bun run config:generate
bun run format:check
bun run lint
bun run typecheck
bun test ./packages/adapters ./packages/cli
```

Changes to the Salix materialization endpoint also require the relevant Salix router and
IM provider tests.
