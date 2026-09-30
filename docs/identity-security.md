# Identity and security

## Ownership

Comma users and BFT members are product identities.
Salix Tenant, Group, Agent and Session define separate execution scopes.
Product operations derive Salix tenants from authorized product records.
Do not trust a client-supplied tenant, owner, template scope, or membership projection as authority.
Restricted sessions cannot manage models or subscription credentials.
Admin entry points enforce authorization independently of UI visibility.

A tenant API key is tenant-level authority. It is not a product member-role check.
Comma and BFT enforce product authorization before calling Salix.
Catalogs exclude secrets. Full configuration access requires separate operator authority.
See [Billing and models](billing-models.md).

## Credential custody

Electron main owns user bearer credentials. Renderers receive typed results, not raw secrets.
Credentials must not enter logs, telemetry labels, generated catalogs, or persistent browser form state.
Bind OAuth attempts and callbacks to the initiating owner and operation.
Do not use email or display names as substitutes for stable provider subjects.
A provider connection, a product login, and an Agent runtime binding are not interchangeable.

Telegram Mini App login verifies `initData` HMAC and a 120-second `auth_date` against the active Comma connection. It issues a 15-minute, Group-scoped, read-only `SameSite=None; Secure; Partitioned` Cookie. A valid `Lax` login takes priority. Panel exchanges clear stale Comma Cookies. Another valid account gets 409. Bearer and writes fail.
Telegram Task cards recheck the owner per click, accept only the carded version, and reply to that Task as the owner.

On backend changes, Electron atomically removes foreign active credentials and pending revocations before login.
It preserves current-origin records and unrelated profile data. It neither contacts the old origin nor sends its bearer to the new origin.
Local cleanup does not revoke server sessions. Failed persistence blocks login and permits retry.

## Comma OAuth signing keys

`Comma.OauthIdp.SigningKeys` stores encrypted RSA private keys in the shared `comma_oauth_signing_keys` table.
Steady state has one signing key. At most one pending key can await activation.
Partial unique indexes prevent multiple signing or pending rows. Old keys remain `verify_only` until retirement.
The KEK protects against database-only reads, not database-and-KEK compromise.

Environment specs under `systems/ops/comma-release/environments/` own `oauthIdp: enabled`.
The release reads `KEK_BASE64` from the Secret named by `COMMA_OAUTH_IDP_SECRET_NAME` and materializes `COMMA_OAUTH_IDP_KEK` in the runtime Secret.
The KEK is 32 bytes, base64 encoded. Store it through approved secret operations, never in Git or Helm values.
Signing pairs are generated in the pod, not on operator machines.
A missing signer fails closed.

After KEK provisioning and enablement, create the initial signer:

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.provision_initial!())'
```

### Routine rotation

1. Publish the pending public key.

   ```sh
   bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.prepublish!())'
   ```

2. Wait for the enforced prepublication interval.
3. Activate the pending key.

   ```sh
   bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.activate!())'
   ```

4. Remove the old verification key only after its retirement window.

   ```sh
   bin/comma rpc 'Comma.OauthIdp.SigningKeys.remove!("<old-kid>")'
   ```

Activation refuses before `rotation_prepublish_seconds`, normally 630 seconds.
This covers the contractual ten-minute relying-party JWKS cache plus cooldown margin.
Activation promotes the pending signer and stamps the old key's `retire_after` in one transaction.
Removal refuses while `now < retire_after`.
A pending key can be removed because it has not signed tokens.
Never remove an active signer or hand-edit the key table.

### Compromise response

Use the emergency path only for suspected private-key compromise:

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.rotate_compromised!())'
```

This replaces the signer and removes the compromised key in one transaction.
Use `remove_compromised!/1` for a compromised `verify_only` key.
The bypass intentionally sacrifices ordinary verification continuity.

Notify registered relying-party contacts to discard their JWKS caches.
Cached compromised keys can still verify forged tokens until those caches expire.
New-key tokens can fail at relying parties that still hold the old cache.
Existing relying-party login sessions are not revoked by key rotation. V1 has no back-channel logout.
KEK rotation requires a separately reviewed table re-encryption procedure. Do not add a shortcut.

### Verification

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.list())'
bin/comma rpc 'IO.inspect(Enum.map(Comma.OauthIdp.public_jwks!(), & &1.fields["kid"]))'
```

Inspect the deployed JWKS endpoint and a relying-party login separately.
The key list proves stored state, not every external cache or session.
Source: [signing_keys.ex](../systems/apps/comma_core/lib/comma/oauth_idp/signing_keys.ex).
Current formal coverage is only the roster in [tla/README.md](../tla/README.md).

## Task Share links

A Task Share token is the only authority for public reads of one Task. Reads pass fail-closed rate limits.
See [Task Share](architecture/DOMAIN_CONCEPTS.md#task-share).

## BFT sign-in

Feishu SSO controls dashboard login, not bot routing. Register credentials in organization Settings, then select the SSO app.
Each organization has one active SSO provider. The stable subject within the organization/app binding identifies login.
Email and mobile are optional contact data. Register the SSO card's exact redirect URI.
JIT applies the configured first-login role; linked-only requires an existing identity link.
Organization and Project membership still authorize access. See [Bridge For Teams](bridge-for-teams/design.md) for separate bot setup.

## SSH account access

Comma SSH reuses User, Login Identity and Auth Session. Username `comma` never selects an account.
OTP verifies key possession; the account binding authorizes login. Unknown signed keys reach only enrollment.
Password login, exec, SFTP, forwarding and non-PTY shells are unavailable.

`CommaSSH.KeyCallback` records the latest candidate key for unsigned probes and signed requests.
Success promotes it only after signature verification. `CommaSSH.Connections` binds context to the connection PID,
permits one channel claim, and removes context on exit. Username and network address are not handoff identities.
The adapter relies on pinned OTP callback order. Real SSH tests must pass on OTP upgrades.

Enrollment uses `Comma.AuthChallenges` purpose `ssh_enrollment`, binding the exact key fingerprint and a random connection-local value.
Existing code expiry, consumption, delivery, cooldown and attempt limits apply. Email-login codes cannot enroll keys.
Disconnect drops the binding; enrollment expires after 15 minutes. Transcripts exclude codes and account bearers.

`comma_user_identities` stores the canonical key, fingerprint, account owner,
timestamps and `disabled_at` under `provider=ssh`, `issuer=comma:ssh`.
It permits multiple keys per account and preserves Google's one-identity rule.
The account lock limits enrollment to 50 records, including revoked keys.
Revoked bindings cannot enroll again or transfer; use a new key.

The fingerprint is an index and display value. Lookup also compares the exact
key bytes. The threat is another party claiming a stored account binding with
an unproved or substituted key. OTP owns possession verification. Comma Accounts
owns the expected key/account binding and rejects unknown or revoked authority.
No client-supplied account ID or email substitutes for the verified binding.

SSH creates a 12-hour ordinary Auth Session (`auth_method=ssh_public_key`,
`client_kind=ssh`) linked to its Login Identity. Resolution checks identity
owner and revocation, session expiry and revocation, account status, and auth
epoch. Disconnect revokes the session when cleanup succeeds; expiry bounds
orphans. Reconnection creates a new session. Session revocation does not revoke
the Login Identity.

`GET /v1/comma/auth/ssh-keys` lists up to 50 owned keys. `DELETE
/v1/comma/auth/ssh-keys/:id` revokes an owned key. Both use full-session management
authorization. Restricted support sessions cannot manage keys. Revocation stops
new login and is detected by idle terminals on the next 30-second check, or before their
next command or refresh. Checks time out at 20 seconds. Idle connections
converge to closure within 60 seconds, including terminal output timeouts. The TUI also provides `/keys` and `/revoke KEY_ID`.

### SSH server identity

`Comma.SSHHostKey` creates and stores one Ed25519 keypair as unencrypted PEM in
`comma_ssh_host_keys`. Atomic insertion lets replicas share it after concurrent
startup. The listener starts only with the stored key; malformed data fails
startup without replacement.

Host-key storage relies on database protection; no separate encryption key is
provisioned. Backups retain it. SSH material and lifecycle are separate from
OAuth signing keys. Clients pin the key in `known_hosts`. First use needs a
trusted fingerprint published through an authenticated channel. Rotation is
explicit and can require client trust updates.

The migration preserves all existing account and session facts. It does not
rewrite Google identities or sync a provider. SSH credentials and host keys are
durable, not disposable projections. After enrollment, recovery uses forward
repair. Keep the listener disabled until the schema migration has completed.
The feature does not require an exclusive rollout or a service shutdown.

Sources: [SSH identities](../systems/apps/comma_core/lib/comma/accounts/ssh_identities.ex),
[host key](../systems/apps/comma_core/lib/comma/ssh_host_key.ex),
[OTP authentication](https://github.com/erlang/otp/blob/OTP-29.0.2/lib/ssh/src/ssh_auth.erl).

## Self-hosted email login

`comma.email.provider` selects Postmark or SMTP. Postmark remains the hosted default.
SMTP uses `comma.email.smtp` for host, port, username, password, TLS, and implicit SSL.
TLS verifies the server certificate and hostname. Login-code delivery has a 15-second budget and no automatic retries.
Self-hosted instances retain Redis challenges, ordinary session lifetimes, and no code exposure in API responses.
HTTP cookies are allowed only for an explicit loopback self-hosted origin. Remote origins require HTTPS.
Public Web, Admin, and Product API origins must be distinct but same-site: HTTPS on one registrable domain.
`SameSite=Lax` blocks cross-site use of the login Cookie.
Self-hosted public signup is off by default.
The offline initializer creates `COMMA_OWNER_EMAIL` and grants existing explicit Admin access only when no decision exists.
It preserves explicit denials and does not trust the hosted `comma.surf` email domain.

## Composio trigger authorization

A connected account does not start a watch. An Agent creates or binds a provider trigger to one of its Loops.
Several Loops can share a trigger. Each Loop stores one binding and receives events only while active.
The binding records the settings scope, connected account ID, trigger ID, and trigger slug.
`composio.list_trigger_types` and `composio.get_trigger_type` expose provider configuration and payload schemas.
`composio.create_trigger` creates or reuses a trigger and binds it to the specified Loop.
`composio.bind_trigger` binds an existing group trigger. Omit `trigger_id` to remove the binding.
`composio.list_triggers` returns one page, including disabled triggers, and a cursor for the next page.
`composio.manage_trigger` enables, disables, or deletes a group trigger. The operation affects all subscribers to that provider trigger.
Creation with identical provider configuration can re-enable an existing shared trigger.
Provider operations use Composio v3.1 with no transport retries and an eight-second connect and response timeout.

### Configure ingress

1. Set the Composio API key through the existing settings API.
2. POST `{}` to `/v1/runtime/composio/webhook` with the tenant API key for tenant-owned settings.
3. For deployment defaults, POST `{}` to `/v1/admin/composio/default-webhook` with the admin token instead.
4. Keep the returned `webhook_url` private.
5. Create a Loop that reads `sf_event_next`, then call `composio.create_trigger` with its ID, account ID, slug, and configuration.
6. For Gmail, use `GMAIL_NEW_GMAIL_MESSAGE` and the configuration returned by `composio.get_trigger_type`.

Registration creates or updates the project's V3 subscription for `composio.trigger.message` events.
Composio permits one project subscription. A different existing destination returns `409 existing_project_webhook`.
Use `replace_existing: true` only to replace that destination and its event selection.
Use `rotate: true` to replace the secret URL. Otherwise registration preserves the URL.
After an interrupted provider write, repeat registration. An unknown committed destination needs explicit replacement.
Changing the API key or base URL clears ingress authorization. Register again before creating watches.
Deleting or disabling the settings revokes their ingress. Tenant fallback still follows the existing settings contract.
Use one Salix settings scope per Composio project. Tenants that share the deployment project must use its defaults.

### Event and lifecycle contract

`POST /v1/composio-webhooks/:secret` authenticates with a random 256-bit URL credential owned by the settings record.
Unknown or revoked secrets fail closed before body parsing. Composio signatures are intentionally not verified.
The secret permits event submission within that settings scope. It grants no additional Loop or tool authority.
The receiver checks the group's effective settings and the connected account's current owner and ACTIVE status.
It routes to active Loops whose stored scope, account, trigger ID, and slug match the event.
It signals Comma pooled sources with that trigger and account, without the event data.
The event ID is the provider's V3 `id`, the topic is `metadata.trigger_slug`, and the payload is `data`.
Pause and archive retain bindings but skip events. Resume accepts future events. Loop deletion removes its binding.
Unbinding or deleting a Loop, or removing a pooled source, does not delete the shared provider trigger. Disable or delete it explicitly.
Account expiry or disconnection refuses delivery. Reauthorization does not transfer a binding to the replacement account.
Create or bind a trigger for the replacement account explicitly. List connections and triggers to diagnose inactive state.
An event already admitted or in flight can finish after pause, unbinding, secret rotation, or a settings change.

The JSON body limit is 16 KiB. Larger events return `413` and need a smaller provider configuration.
Ingress allows 6,000 requests globally, 600 per settings scope, and 60 per group each minute.
An indexed lookup selects at most 100 active subscribers per group. A pipeline delivers with at most 20 concurrent owner calls.
Each owner call has a five-second deadline. There is no per-account polling or full Loop scan in Salix.
Composio controls observation frequency. Gmail polls, without push delivery.
`202` means durable admission to each matching active Loop and pooled source, or none. It does not mean completed processing.
Each Loop atomically rechecks its current binding before saving the event. See [Loop recovery](salix/tasks-background-execution.md#background-loops).
Mailbox pressure returns `429`. Dependency or partial fan-out failure returns `503`. Retry with the same provider event ID.
The Loop ledger deduplicates acknowledged events. Unacknowledged processing can repeat after failures.
Use stable `agent.notify` deduplication keys and acknowledge only after the required work completes.
Loop-owned pending events recover admitted work. There is no provider-history backfill or exactly-once guarantee.

Loop programs may call `composio.execute` for provider reads and writes through tool disclosure and IFC.
The tool remains write-classified. Loop trigger creation, binding, and management run in normal Agent rounds.
Provider arguments remain program-controlled. Incoming mail is event data, not authority to choose tools or destinations.

Implementation: [trigger tools](../systems/apps/salix_agent/lib/salix_agent/tools/composio_triggers.ex),
[ingress](../systems/apps/salix_web/lib/salix_web/composio_webhook.ex),
[provider API](https://docs.composio.dev/reference/api-reference/triggers).

### Comma proactive attention

Routine settings can turn automatic messages off. They are on by default.
Off stops their collection. On again starts a new pool baseline.
Home entry starts one collection chain per owner, every 15 minutes, until the owner loses the Workspace.
Collection reads member sources only through the Routine collector, which checks current consent and bindings.
Member Routine runs read the pool. With ingress, the owner's Gmail source keeps one trigger.
Its events schedule a read of that source at most once a minute.
The item pool keeps bounded excerpts, not raw payloads, for 5 days after they were last seen.
Revocation, rebinding or source removal deletes that source's items at once.
One bounded judgment uses the owner's Router template without tools. Source text is untrusted evidence.
The server accepts only a pooled item ID, a critical urgency and plain text.
ConversationActor enforces the switch and limits automatic messages: one hour apart, three per 24 hours.

Watches start only on an owner request. Enrollment pins Router Session, owner, Workspace, account and consent revision.
The host checks these around reads and before Router admission.
Composio pins allowed reads and nested event arguments. Internal reads bound one Conversation.
Sources cannot choose tools or recipients.
recommendation.read neither fetches sources nor starts runs. Missing profiles create no state.

A watch Loop uses existing reads, Decide and agent.notify. Only complete quiet decisions with confidence >=9000 basis points bypass Router.
Missing or oversized evidence requires Router reads. Checkpoints precede acknowledgment.
Polling permits five minutes to 24 hours. No backfill or exactly-once external delivery guarantee applies.
Re-enrollment updates the same Loop. Pending work blocks source changes.

proactive.state, .watch, .present and .act require current owner authority.
Handled and replacement snooze fence stale appends. Ambiguous replies require clarification. Actions grant no external-write authority.

Participants deliver only to bound personal Telegram/WeChat peers.
Before network I/O, each delivery checks binding, peer, owner, generation and reminder state.
Saved messages do not prove receipt. Uncertain outcomes do not resend. Checks are not atomic provider transactions.

The comma_mail receiver rechecks published source/Home context. An undecidable recheck still delivers the owner's reminder.
Task Actor rejects continuation of completed, cancelled, archived or ready-for-review Tasks. Receipts recover uncertain Task creation.

## IM route retirement

BFT archival transactionally queues tenant/group-scoped retirement for active and disabled routes, even without a Salix group.
Validate canonical tenant/group IDs and physical connect keys. Group deletion retires routes first; org credentials survive.
CAS tombstones connects before identity release. Retries include tombstones. Slack generation and WeChat released-identity fences remain.
Existing reconcile telemetry reports retries/failures. Previously archived projects need scoped cleanup, not a global scan.
Runtime tests cover this lifecycle; no new TLA+ property or cross-store atomicity is claimed.
