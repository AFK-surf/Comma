# Identity and security

## Ownership

Comma User and BFT Member are product identities. Salix Tenant, Group, Agent and Session are execution scopes.
Authorized product records determine Salix tenants.
Client tenant, owner, template scope and membership projections are not authority.
Restricted sessions cannot manage models or subscription credentials.
Admin entry points authorize regardless of UI visibility.

Tenant API keys do not check product member roles.
Comma and BFT authorize before Salix calls.
Catalogs exclude secrets. Full configuration requires operator authority.
See [Billing and models](billing-models.md).

## Credential custody

Electron Main owns bearers. Renderers receive typed results without secrets.
Exclude credentials from logs, telemetry labels, catalogs and persistent browser forms.
Bind OAuth attempts and callbacks to the initiating owner and operation.
Do not use email or display names as substitutes for stable provider subjects.
Provider connections, product logins and Agent runtime bindings are distinct.

Telegram Mini App login verifies `initData` HMAC and a 120-second `auth_date` against the active Comma connection. It issues a 24-hour, Group-scoped, read-only `SameSite=None; Secure; Partitioned` Cookie. A valid `Lax` login takes priority. Panel exchanges clear stale Comma Cookies. Another valid account gets 409. Bearer and writes fail.
Telegram Task cards recheck the owner per click, accept only the carded version, and reply to that Task as the owner.

Backend changes atomically remove foreign credentials and pending revocations before Electron login.
Preserve current-origin records and unrelated profile data. Never contact the old origin or send its bearer to the new origin.
Local cleanup does not revoke server sessions. Persistence failure blocks login until retry.

## Native Apple credentials

[CommaCore](../clients/packages/apple-core/Sources/CommaCore/CommaClient.swift) keeps iOS/Watch Auth Sessions in origin-bound Keychain records.
Views receive session facts. Widgets and WatchConnectivity receive no account bearers.
Auth requests require `x-comma-session-transport: bearer`. Product requests reject redirects/foreign origins.
Logout clears credentials after successful remote revocation. Failure retains login for explicit retry.
Apple credential revocation clears local authority. Local removal alone cannot revoke server sessions.

Set `comma.apple_auth.client_id` or `COMMA_APPLE_CLIENT_ID` to the iOS bundle ID. Missing configuration returns `503 apple_not_configured`.
[AppleAuth](../systems/apps/comma_core/lib/comma/apple_auth.ex) verifies RS256 using Apple's fixed HTTPS JWKS, issuer, audience, nonce, expiry and issue time.
Apple owns expected signing keys. Comma owns expected client ID and a five-minute, single-use nonce attempt. Invalid proof rejects login.
Login Identity uses Apple's stable subject. Submitted email is not identity. First login requires Apple's verified email.
Existing emails require mailbox OTP before linking, preventing unproved takeover.

Phone delegates a two-minute, single-use Watch grant. Watch exchanges it for its own Auth Session and direct HTTPS access.
Restricted sessions cannot delegate. Parent revocation rejects grants/Watch sessions.
Phone disconnection or natural parent expiry leaves issued Watch sessions valid until their own expiry.
Apple authorization-code exchange, server revocation notifications and self-service account deletion remain absent. App Store readiness is unverified.

APNs uses secret `config.json` profiles `comma.apns.{sandbox,production}`. See [policy](clients.md#native-apple-clients).
Keep private keys outside Git. Bundle ID must match signed iOS identity and APNs topic.
[Notification targets](../systems/apps/comma_core/lib/comma/notifications.ex) bind tokens to current Auth Session and authorized Workspace/Task.
APNs signing proves the configured Apple sender, not product authority. Missing configuration returns `push_unavailable`.
Validate best-effort delivery on signed devices.

## Comma OAuth signing keys

`Comma.OauthIdp.SigningKeys` encrypts RSA private keys in shared `comma_oauth_signing_keys`.
One signer and at most one pending key exist.
Partial unique indexes enforce signer/pending uniqueness. Old keys remain `verify_only` until retirement.
The KEK protects against database-only reads, not database-and-KEK compromise.

Environment specs under `systems/ops/comma-release/environments/` own `oauthIdp: enabled`.
Release maps `KEK_BASE64` from Secret `COMMA_OAUTH_IDP_SECRET_NAME` to runtime Secret `COMMA_OAUTH_IDP_KEK`.
The KEK is 32 base64-encoded bytes. Use approved secret operations, never Git or Helm values.
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
This covers ten-minute relying-party JWKS caches plus cooldown margin.
Activation promotes the pending signer and stamps the old key's `retire_after` in one transaction.
Removal refuses while `now < retire_after`.
Unsigned pending keys can be removed.
Never remove an active signer or hand-edit the key table.

### Compromise response

Use the emergency path only for suspected private-key compromise:

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.rotate_compromised!())'
```

This replaces the signer and removes the compromised key in one transaction.
Use `remove_compromised!/1` for a compromised `verify_only` key.
The bypass sacrifices verification continuity.

Notify registered relying-party contacts to discard their JWKS caches.
Cached compromised keys can still verify forged tokens until those caches expire.
New-key tokens can fail at relying parties that still hold the old cache.
Rotation does not revoke relying-party sessions. V1 has no back-channel logout.
KEK rotation requires separately reviewed table re-encryption. No shortcuts.

### Verification

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.list())'
bin/comma rpc 'IO.inspect(Enum.map(Comma.OauthIdp.public_jwks!(), & &1.fields["kid"]))'
```

Verify deployed JWKS and relying-party login separately.
The key list proves stored state, not external caches/sessions.
[Implementation](../systems/apps/comma_core/lib/comma/oauth_idp/signing_keys.ex).
Current formal coverage is only the roster in [tla/README.md](../tla/README.md).

## Task Share links

A Task Share token alone authorizes public reads of one Task. Reads enforce fail-closed rate limits.
See [Task Share](architecture/DOMAIN_CONCEPTS.md#task-share).

## BFT sign-in

Feishu SSO authorizes dashboard login, not bot routing. Register credentials in organization Settings and select the SSO app.
Each organization has one active SSO provider. Its organization/app-scoped subject identifies login.
Email and mobile are optional contact data. Register the SSO card's exact redirect URI.
JIT applies the configured first-login role; linked-only requires an existing identity link.
Organization/Project membership authorizes access. See [Bridge For Teams](bridge-for-teams/design.md) for bot setup.

## SSH account access

SSH reuses User, Login Identity and Auth Session. Username `comma` selects no account.
OTP verifies key possession. The stored account binding authorizes login. Unknown signed keys reach enrollment only.
Password, exec, SFTP, forwarding and non-PTY shells are unavailable.

`CommaSSH.KeyCallback` records the latest unsigned/signed candidate and promotes only verified signatures.
`CommaSSH.Connections` binds context to the connection PID, permits one channel claim, and removes context on exit.
Username/address are not handoff identities. Verify pinned OTP callback order with real SSH after upgrades.

`AuthChallenges` purpose `ssh_enrollment` binds the exact fingerprint and a random connection-local value.
Existing expiry, consumption, delivery, cooldown and attempt limits apply. Email-login codes cannot enroll keys.
Disconnect removes the binding. Enrollment expires after 15 minutes. Transcripts exclude codes and bearers.

`comma_user_identities` owns keys, fingerprints, owners, timestamps and `disabled_at` (`provider=ssh`, `issuer=comma:ssh`).
Accounts permit multiple SSH keys and one Google identity. Locked enrollment permits 50 records, including revoked keys.
Revoked keys cannot enroll again or transfer. Use a new key.
Fingerprints index and display keys. Lookup also compares exact bytes.
OTP verifies possession against substitution or unproved ownership. Accounts rejects unknown/revoked key bindings.
Client account IDs and emails cannot replace it.

SSH issues 12-hour ordinary Auth Sessions (`auth_method=ssh_public_key`, `client_kind=ssh`) linked to Login Identity.
Resolution checks identity owner/revocation, session expiry/revocation, account status and auth epoch.
Disconnect revokes when cleanup succeeds. Expiry bounds orphans. Reconnection creates a session. Session revocation does not revoke Login Identity.

`GET /v1/comma/auth/ssh-keys` lists at most 50 owned keys. `DELETE /v1/comma/auth/ssh-keys/:id` revokes one.
Both require full-session management authority. Restricted support sessions cannot manage keys.
Revocation stops login. Terminals detect it before their next command/refresh or at the next 30-second idle check.
Checks expire after 20 seconds. Closure takes at most 60 seconds, including output timeouts.
The TUI offers `/keys` and `/revoke KEY_ID`.

### SSH server identity

`Comma.SSHHostKey` stores one Ed25519 keypair as unencrypted PEM in `comma_ssh_host_keys`.
Atomic insertion shares it across concurrent replica startup. The listener requires the stored key. Malformed data fails startup without replacement.
Database protection/backups preserve it without separate encryption. Its lifecycle differs from OAuth keys.
Clients pin `known_hosts`. First use requires an authenticated fingerprint. Explicit rotation can require trust updates.

Migration preserves accounts, sessions and Google identities without provider sync.
SSH credentials and host keys are durable. Recovery after enrollment uses forward repair.
Keep the listener disabled until schema migration completes. No exclusive rollout or shutdown is required.
Source: [SSH identities](../systems/apps/comma_core/lib/comma/accounts/ssh_identities.ex).

## Self-hosted email login

`comma.email.provider` selects Postmark or SMTP. Postmark remains the hosted default.
`comma.email.smtp` defines host, port, username, password, TLS and implicit SSL.
TLS verifies the server certificate and hostname. Login-code delivery has a 15-second budget and no automatic retries.
Self-hosted instances retain Redis challenges and ordinary session lifetimes. API responses expose no codes.
HTTP cookies are allowed only for an explicit loopback self-hosted origin. Remote origins require HTTPS.
Web, Admin and Product API require distinct, same-site HTTPS origins on one registrable domain.
`SameSite=Lax` blocks cross-site use of the login Cookie.
Self-hosted public signup is off by default.
Offline initialization creates `COMMA_OWNER_EMAIL` and grants explicit Admin access only without an existing decision.
It preserves explicit denials and does not trust the hosted `comma.surf` email domain.

## Composio trigger authorization

Connected accounts do not start watches. Agents bind provider triggers to Loops.
Loops can share triggers. Each stores one binding and receives events only while active.
Bindings record settings scope, account ID, trigger ID and slug.
`composio.list_trigger_types` and `composio.get_trigger_type` expose provider configuration and payload schemas.
`composio.create_trigger` creates or reuses a trigger and binds it to the specified Loop.
`composio.bind_trigger` binds an existing group trigger. Omit `trigger_id` to remove the binding.
`composio.list_triggers` returns a page including disabled triggers and its next cursor.
`composio.manage_trigger` enables, disables, or deletes a group trigger. It affects all trigger subscribers.
Identical provider configuration can re-enable a shared trigger.
Provider operations use Composio v3.1 with no transport retries and an eight-second connect and response timeout.

### Configure ingress

1. Set the Composio API key through the existing settings API.
2. POST `{}` to `/v1/runtime/composio/webhook` with the tenant API key for tenant-owned settings.
3. For deployment defaults, POST `{}` to `/v1/admin/composio/default-webhook` with the admin token instead.
4. Keep the returned `webhook_url` private.
5. Create a Loop that reads `sf_event_next`, then call `composio.create_trigger` with its ID, account ID, slug, and configuration.
6. For Gmail, use `GMAIL_NEW_GMAIL_MESSAGE` and the configuration returned by `composio.get_trigger_type`.

Registration updates project V3 `composio.trigger.message` subscriptions.
Composio permits one project subscription. A different existing destination returns `409 existing_project_webhook`.
`replace_existing: true` replaces its destination and event selection.
`rotate: true` replaces the secret URL. Otherwise preserve it.
Retry interrupted registration. Unknown committed destinations require explicit replacement.
API key/base URL changes clear ingress authority. Register before new watches.
Deleting/disabling settings revokes ingress. Tenant fallback follows the settings contract.
Use one settings scope per Composio project. Shared deployment projects require deployment defaults.

### Event and lifecycle contract

`POST /v1/composio-webhooks/:secret` authenticates with a random 256-bit URL credential owned by the settings record.
Unknown or revoked secrets fail closed before body parsing. Composio signatures are intentionally not verified.
The secret permits event submission within that settings scope. It grants no additional Loop or tool authority.
The receiver checks effective group settings and current connected-account owner/ACTIVE status.
It routes to active Loops whose stored scope, account, trigger ID, and slug match the event.
It signals matching Comma pooled sources by trigger/account, without event data.
Event identity uses V3 `id`, topic `metadata.trigger_slug` and payload `data`.
Pause and archive retain bindings but skip events. Resume accepts future events. Loop deletion removes its binding.
Unbinding/deleting Loops or pooled sources preserves shared triggers. Disable/delete triggers explicitly.
Expired/disconnected accounts reject delivery. Reauthorization does not transfer bindings.
Bind replacement accounts explicitly. Diagnose inactive state through connection/trigger lists.
Admitted/in-flight events can finish after pause, unbinding, secret rotation or settings changes.

JSON bodies over 16 KiB return `413`. Reduce provider configuration.
Ingress allows 6,000 requests globally, 600 per settings scope, and 60 per group each minute.
Indexed lookups select at most 100 active subscribers per group. Delivery permits 20 concurrent owner calls.
Owner calls expire after five seconds. Salix neither polls accounts nor scans all Loops.
Composio controls observation frequency. Gmail polls, without push delivery.
`202` means durable admission to each matching active Loop and pooled source, or none. It does not mean completed processing.
Each Loop atomically rechecks its binding before event storage. See [Loop recovery](salix/tasks-background-execution.md#background-loops).
Mailbox pressure returns `429`. Dependency/partial fan-out failures return `503`. Retry the same provider event ID.
Loop ledgers deduplicate acknowledged events. Unacknowledged processing can repeat after failure.
Use stable `agent.notify` deduplication keys and acknowledge only after the required work completes.
Loop pending events recover admitted work without provider backfill or exactly-once guarantees.

Loop programs may call `composio.execute` for provider reads and writes through tool disclosure and IFC.
The tool remains write-classified. Trigger creation, binding and management require normal Agent rounds.
Programs control provider arguments. Incoming mail cannot authorize tools or destinations.

Implementation: [trigger tools](../systems/apps/salix_agent/lib/salix_agent/tools/composio_triggers.ex),
[ingress](../systems/apps/salix_web/lib/salix_web/composio_webhook.ex),
[provider API](https://docs.composio.dev/reference/api-reference/triggers).

### Comma proactive attention

Routine automatic messages default on.
Off stops collection. Re-enabling starts a new pool baseline.
Home starts one collection chain per owner every 15 minutes, until Workspace loss.
Only the Routine collector reads member sources, with current consent/bindings.
Member Routines read the pool. Ingress keeps one trigger for the owner Gmail source.
Its events schedule a read of that source at most once a minute.
The pool keeps bounded excerpts, without raw payloads, for five days after last observation.
Revocation, rebinding or source removal deletes that source's items at once.
One bounded, toolless judgment uses the owner Router template. Sources are untrusted.
The server accepts only pooled item IDs, critical urgency and plain text.
ConversationActor enforces the switch and limits automatic messages: one hour apart, three per 24 hours.

Owner requests start watches. Enrollment pins Router Session, owner, Workspace, account and consent revision.
The host checks them around reads and before Router admission.
Composio pins allowed reads and nested event arguments. Internal reads bound one Conversation.
Sources cannot choose tools or recipients.
recommendation.read neither fetches sources nor starts runs. Missing profiles create no state.

A watch Loop uses existing reads, Decide and agent.notify. Only complete quiet decisions with confidence >=9000 basis points bypass Router.
Missing/oversized evidence requires Router reads. Checkpoint before acknowledgment.
Poll intervals span five minutes to 24 hours, without backfill or exactly-once delivery.
Re-enrollment updates the same Loop. Pending work blocks source changes.

proactive.state, .watch, .present and .act require current owner authority.
Handled/replacement snooze fence stale appends. Clarify ambiguous replies. Actions grant no external-write authority.

Participants deliver only to bound personal Telegram/WeChat peers.
Before network I/O, each delivery checks binding, peer, owner, generation and reminder state.
Saved messages do not prove receipt. Never resend uncertain outcomes. Checks lack atomic provider transactions.

comma_mail rechecks published source/Home context. Undecidable rechecks still deliver the owner reminder.
Task Actor rejects continuation of completed, cancelled, archived or ready-for-review Tasks. Receipts recover uncertain creation.

## IM route retirement

BFT archival transactionally queues tenant/group-scoped retirement for active/disabled routes, even without a Salix group.
Validate canonical tenant/group IDs and physical connect keys. Retire routes before Group deletion. Preserve org credentials.
CAS tombstones connects before identity release. Retries include tombstones. Slack generation and WeChat released-identity fences remain.
Reconcile telemetry reports retries/failures. Previously archived projects require scoped cleanup, never global scans.
Runtime tests cover lifecycle, without new TLA+ properties or cross-store atomicity.
