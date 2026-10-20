# Identity and security

## Ownership

Comma User and BFT Member are product identities. Salix Tenant, Group, Agent and Session are execution scopes.
Product records authorize Salix tenants. Client projections grant no authority.
Restricted sessions cannot manage models or subscription credentials.
Admin entry points authorize regardless of UI visibility.
Tenant API keys do not check product member roles. Comma and BFT authorize before Salix calls.
Catalogs exclude secrets. Full configuration requires operator authority. See [Billing and models](billing-models.md).

## Admin login sessions

Auth Sessions are not Devices. Active means unexpired and unrevoked, not online.
The default list shows active sessions by last use. Server filters apply before pagination. Counts describe loaded rows.
Revocation requires a reason. Revoke all also requires the typed target and ignores filters.

## Credential custody

Electron bearers stay in Main.
Exclude credentials from logs, telemetry labels, catalogs and persistent browser forms.
Bind OAuth attempts and callbacks to the initiating owner and operation.
Names and emails cannot replace stable provider subjects.
Provider connections, product logins and Agent runtime bindings differ.

Telegram Mini App login verifies the `initData` HMAC and a 120-second `auth_date` against the active Comma connection.
It issues a 24-hour, Group-scoped, read-only `SameSite=None; Secure; Partitioned` Cookie.
Valid `Lax` logins take priority. Panel exchanges clear stale Comma Cookies. Another valid account gets 409. Bearer requests and writes fail.

A backend change atomically removes foreign credentials and pending revocations before Electron login.
Keep current-origin records and unrelated profile data. Never contact the old origin or send its bearer to the new origin.
Local cleanup leaves server sessions intact. Persistence failure blocks login until retry.
Desktop keeps valid challenges and cooldowns on same-email reentry or retryable resend errors.

## Review login codes

After release, select the User in Admin, explicitly deny Admin access, then choose **Review login code** in account actions.
Set six digits, replace them, or remove the code to restore email OTP. Fixed codes never expire; auth-key rotation requires saving them again.
Removal preserves Admin deny and existing sessions. Use session revocation separately.
Keep the code and login steps in App Review Notes. iOS keeps its email/code form.
Use dedicated demo accounts: long-lived six-digit codes remain guessable.
See [credential ownership and verification](architecture/DOMAIN_CONCEPTS.md#review-login-credential).

## Native Apple credentials

[CommaCore](../clients/packages/apple-core/Sources/CommaCore/Client/Credentials.swift) keeps iOS and Watch Auth Sessions in origin-bound Keychain records.
Views receive session facts. Widgets and WatchConnectivity receive no account bearers.
Auth requests require `x-comma-session-transport: bearer`. Product requests reject redirects and foreign origins.
Logout clears credentials after successful remote revocation. Failure keeps the login for explicit retry.
Apple credential revocation clears local authority. Local removal alone cannot revoke server sessions.

[AppleAuth](../systems/apps/comma_core/lib/comma/apple_auth.ex) verifies RS256 with Apple's fixed HTTPS JWKS, issuer, audience, nonce, expiry and issue time.
Comma owns the expected client ID and a five-minute, single-use nonce attempt. Invalid proof rejects login.
Login Identity uses Apple's stable subject, not the submitted email. First login requires Apple's verified email.
Existing emails require mailbox OTP before linking.

A two-minute, single-use phone grant gives Watch its own Auth Session for direct HTTPS access.
Restricted sessions cannot delegate. Parent revocation rejects grants and Watch sessions.
Phone disconnection or natural parent expiry leaves issued Watch sessions valid until their own expiry.

APNs configuration and delivery rules are in [Native Apple clients](clients.md#native-apple-clients). Keep private keys outside Git.

## Comma OAuth signing keys

Environment specs under `systems/ops/comma-release/environments/` own `oauthIdp: enabled`.
Release maps `KEK_BASE64` from Secret `COMMA_OAUTH_IDP_SECRET_NAME` to runtime Secret `COMMA_OAUTH_IDP_KEK`.
The KEK is 32 base64-encoded bytes. Use approved secret operations, not Git or Helm values.
The pod generates signing pairs. Missing signers fail closed.

After you enable the IdP and provision the KEK, create the signer:

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.provision_initial!())'
```

### Routine rotation

1. Publish the pending public key.

   ```sh
   bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.prepublish!())'
   ```

2. Wait for the prepublication interval.
3. Activate the pending key.

   ```sh
   bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.activate!())'
   ```

4. Remove the old verification key only after its retirement window.

   ```sh
   bin/comma rpc 'Comma.OauthIdp.SigningKeys.remove!("<old-kid>")'
   ```

Activation refuses before `rotation_prepublish_seconds` (default 630 seconds: ten-minute JWKS caches plus cooldown).
Activation atomically promotes the pending signer and stamps the old key's `retire_after`.
Removal refuses while `now < retire_after`. You can remove unsigned pending keys.
Never remove an active signer or hand-edit the key table.

### Compromise response

Use the emergency path only for suspected private-key compromise:

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.rotate_compromised!())'
```

This atomically replaces the signer and removes the compromised key.
Use `remove_compromised!/1` for a compromised `verify_only` key. Both sacrifice verification continuity.

Tell registered relying-party contacts to discard their JWKS caches.
Cached compromised keys can verify forged tokens until those caches expire.
New-key tokens can fail at relying parties that still hold the old cache.
Rotation does not revoke relying-party sessions. V1 has no back-channel logout.
KEK rotation requires separately reviewed table re-encryption.

### Verification

```sh
bin/comma rpc 'IO.inspect(Comma.OauthIdp.SigningKeys.list())'
bin/comma rpc 'IO.inspect(Enum.map(Comma.OauthIdp.public_jwks!(), & &1.fields["kid"]))'
```

Formal coverage: [current roster](../tla/README.md).

## Task Share links

A Task Share token alone authorizes public reads of one Task. Reads enforce fail-closed rate limits.
See [Task Share](architecture/DOMAIN_CONCEPTS.md#task-share).

## BFT sign-in

Feishu or Lark SSO authorizes dashboard login, not bot routing. Feishu selects its SSO app in Settings. Lark stores its own app there.
Each organization has one active SSO provider. Its organization- and app-scoped subject identifies login.
Email and mobile are optional contact data. Register the exact redirect URI from the SSO card.
JIT applies the configured first-login role. Linked-only requires an existing identity link.
Organization and Project membership authorize access. See [Bridge For Teams](bridge-for-teams/design.md) for bot setup.

## SSH account access

SSH reuses User, Login Identity and Auth Session. Username `comma` selects no account.
OTP verifies key possession. The stored account binding authorizes login. Unknown signed keys reach enrollment only.
Password, exec, SFTP, forwarding and non-PTY shells are unavailable.

`AuthChallenges` purpose `ssh_enrollment` binds the exact fingerprint and a random connection-local value.
Existing expiry, consumption, delivery, cooldown and attempt limits apply. Email-login codes cannot enroll keys.
Disconnect removes the binding. Enrollment expires after 15 minutes. Transcripts exclude codes and bearers.

SSH issues 12-hour ordinary Auth Sessions (`auth_method=ssh_public_key`, `client_kind=ssh`) linked to the Login Identity.
Resolution checks identity owner and revocation, session expiry and revocation, account status and auth epoch.
Disconnect revokes the session when cleanup succeeds. Expiry bounds orphans. Reconnection creates a new session.
Session revocation does not revoke the Login Identity.

`GET /v1/comma/auth/ssh-keys` lists at most 50 owned keys. `DELETE /v1/comma/auth/ssh-keys/:id` revokes one.
Both require full-session management authority. Restricted support sessions cannot manage keys.

### SSH server identity

`Comma.SSHHostKey` stores one Ed25519 keypair as unencrypted PEM in `comma_ssh_host_keys`.
Atomic insertion shares it across concurrent replica startup. The listener requires the stored key. Malformed data fails startup without replacement.
Database protection and backups preserve it without separate encryption. Its lifecycle differs from OAuth keys.
Clients pin `known_hosts`. First use requires an authenticated fingerprint. Explicit rotation can require trust updates.

SSH credentials and host keys are durable. Recovery after enrollment uses forward repair.
Keep the listener disabled until the schema migration completes.
Source: [SSH identities](../systems/apps/comma_core/lib/comma/accounts/ssh_identities.ex).

## Self-hosted email login

`comma.email.smtp` defines host, port, username, password, TLS and implicit SSL.
TLS verifies the server certificate and hostname. Login-code delivery has a 15-second budget and no automatic retries.
Self-hosted instances keep Redis challenges and normal session lifetimes. APIs expose no codes.
HTTP Cookies require an explicit loopback self-hosted origin. Remote origins require HTTPS.
Web, Admin and Product API require distinct, same-site HTTPS origins on one registrable domain.
`SameSite=Lax` blocks cross-site use of the login Cookie. Public self-hosted signup defaults to off.
Offline initialization creates `COMMA_OWNER_EMAIL`. It grants explicit Admin access only when no decision exists.
It preserves denials and does not trust the hosted `comma.surf` domain.

## Composio trigger authorization

Connected accounts do not start watches. Agents bind provider triggers to Loops.
Loops can share triggers. Each Loop stores one binding and receives events only while active.
Bindings record settings scope, account ID, trigger ID and slug.

### Configure ingress

1. Set the Composio API key through the existing settings API.
2. For tenant-owned settings, POST `{}` to `/v1/runtime/composio/webhook` with the tenant API key.
3. For deployment defaults, POST `{}` to `/v1/admin/composio/default-webhook` with the admin token instead.
4. Keep the returned `webhook_url` private.
5. Create a Loop that reads `sf_event_next`. Then call `composio.create_trigger` with its ID, account ID, slug, and configuration.
6. For Gmail, use `GMAIL_NEW_GMAIL_MESSAGE` and the configuration from `composio.get_trigger_type`.

Registration updates project V3 `composio.trigger.message` subscriptions.
Composio permits one project subscription. A different existing destination returns `409 existing_project_webhook`.
`replace_existing: true` replaces its destination and event selection. `rotate: true` replaces the secret URL.
Retry interrupted registration. Unknown committed destinations require explicit replacement.
API key or base URL changes clear ingress authority. Register again before new watches.
Deleting or disabling settings revokes ingress. Tenant fallback follows the settings contract.
Use one settings scope per Composio project. Shared deployment projects require deployment defaults.

### Event and lifecycle contract

`POST /v1/composio-webhooks/:secret` authenticates with a random 256-bit URL credential owned by the settings record.
Unknown or revoked secrets fail closed before body parsing. Salix does not verify Composio signatures.
The secret permits event submission within that settings scope. It grants no Loop or tool authority.
The receiver checks effective group settings and the current connected-account owner and ACTIVE status.
It routes to active Loops whose stored scope, account, trigger ID, and slug match the event.
It signals matching Comma pooled sources by trigger and account, without event data.
Event identity uses V3 `id`, topic `metadata.trigger_slug` and payload `data`.
Pause and archive keep bindings but skip events. Resume accepts future events. Loop deletion removes its binding.
Unbinding or deleting Loops or pooled sources preserves shared triggers. Disable or delete triggers explicitly.
Expired or disconnected accounts reject delivery. Reauthorization does not transfer bindings. Bind replacement accounts explicitly.
Admitted or in-flight events can finish after pause, unbinding, secret rotation or settings changes.

Salix neither polls accounts nor scans all Loops. Composio controls observation frequency. Gmail polls and has no push delivery.
`202` means durable admission to each matching active Loop and pooled source, or none. It does not mean completed processing.
Each Loop atomically rechecks its binding before event storage. See [Loop recovery](salix/tasks-background-execution.md#background-loops).
Mailbox pressure returns `429`. Dependency or partial fan-out failures return `503`. Retry the same provider event ID.
Loop ledgers deduplicate acknowledged events. Unacknowledged processing can repeat after failure.
Use stable `agent.notify` deduplication keys. Acknowledge only after the required work completes.
Pending events recover admitted work without provider backfill or exactly-once guarantees.

Loop programs can call `composio.execute` for provider reads and writes through tool disclosure and IFC.
The tool stays write-classified. Trigger creation, binding and management require normal Agent rounds.
Programs control provider arguments. Incoming mail cannot authorize tools or destinations.
Code: [trigger tools](../systems/apps/salix_agent/lib/salix_agent/tools/composio_triggers.ex), [ingress](../systems/apps/salix_web/lib/salix_web/composio_webhook.ex).

### Comma proactive attention

Routine automatic messages default on. Off stops collection. Re-enabling starts a new pool baseline.
Home starts one collection chain per owner every 15 minutes, until Workspace loss.
Only the Routine collector reads member sources, with current consent and bindings. Member Routines read the pool.
Ingress keeps one trigger for the owner Gmail source. Its events schedule a read of that source at most once a minute.
The pool keeps bounded excerpts, without raw payloads, for five days after last observation.
Revocation, rebinding or source removal deletes the items of that source at once.
One bounded, toolless judgment uses the owner Router's model. Sources are untrusted.
The server accepts only pooled item IDs, critical urgency and plain text.
ConversationActor enforces the switch and limits automatic messages to one per hour and three per 24 hours.

Owner requests start watches. Enrollment pins Router Session, owner, Workspace, account and consent revision.
The host checks them around reads and before Router admission.
Composio pins allowed reads and nested event arguments. Internal reads bound one Conversation.
Sources cannot choose tools or recipients.
`recommendation.read` neither fetches sources nor starts runs. Missing profiles create no state.

`proactive.state`, `.watch`, `.present` and `.act` require current owner authority.
Handled and replacement snoozes fence stale appends. Clarify ambiguous replies. Actions grant no external-write authority.

Participants deliver only to bound personal Telegram or WeChat peers.
Before network I/O, each delivery checks binding, peer, owner, generation and reminder state.
Saved messages do not prove receipt. Never resend uncertain outcomes. Checks have no atomic provider transactions.

Task Actor rejects continuation of completed, cancelled, archived or ready-for-review Tasks. Receipts recover uncertain creation.

## IM route retirement

BFT archival transactionally queues tenant- and group-scoped retirement for active and disabled routes, even without a Salix group.
Validate canonical tenant and group IDs and physical connect keys. Retire routes before Group deletion. Preserve org credentials.
CAS tombstones connects before identity release. Retries include tombstones. Slack generation and WeChat released-identity fences remain.
Reconcile telemetry reports retries and failures. Previously archived projects require scoped cleanup, never global scans.
