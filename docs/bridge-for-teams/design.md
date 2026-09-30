# Bridge For Teams

## Product boundary

BFT owns users, organizations, Projects, membership, setup, and product navigation.
A Project maps one-to-one to a Salix Group.
Salix owns execution identity, Conversations, Participants, device facts, and runtime dispatch.
Web and CLI use the same product API and authorization boundary.
A dashboard projection is not a second runtime authority.

The Chinese [user manual](../user_manual/bridge_for_teams/manual_zh.tex) covers dashboard operations.
The repository manual workflow builds its PDF. Generated PDFs and screenshots belong outside the tracked docs inventory.

## Slack Task commands

`/newgpttask <text>` submits `Create a task using a Codex worker. Task content: <text>` to the connected Group's Router.
`/newclaudetask <text>` submits `Create a task using a Claude worker. Task content: <text>` to the same Router.
Both commands preserve the input text after the prefix. Normal Task admission and worker availability still apply.
The public endpoint is `POST /v1/im/slack/commands`. It verifies the Slack signature, App, and workspace before delivery.
After authentication, one `conversations.info` read checks access with the connected bot token. Commands require channel membership or an accessible bot DM.
An inaccessible channel returns a private invitation prompt before Router delivery. Archived channels, missing read scopes, and failed checks return private repair or retry guidance.
Channel checks use 500 ms phase timeouts. The whole callback has one 2.5-second deadline.
This preflight checks current membership, not future posting success. Slack posting restrictions or later access changes can still prevent replies.
The trigger ID supplies the inbox deduplication key. Empty input returns a private usage message.
The bot publishes attributed user input first. Router replies and Task cards use that thread. Success returns an empty ACK.
### Admin-managed aliases

Salix Admin, Slack commands, manages aliases for the selected organization's App.
IM Connect owns each App's commands and synchronization state.
An alias has a name, description, usage hint, literal prompt prefix, and enabled flag.
The callback appends user input to the prefix. Include a separator. Router authorization and admission still apply.
New Apps have no aliases. A one-time migration preserves legacy aliases locally without changing Slack registration or permissions.
Tenant configs own organization presets. New catalogs start empty. System presets are separate.
Selecting a preset fills an editable draft. Publishing saves independent App values without inheritance.
Template changes never update Apps or Slack. Copies reject name conflicts and stale revisions.
Empty catalogs stay empty. Templates never cross tenants. App rebinding resets local aliases.

Only the authenticated admin dashboard exposes mutation, with tenant, connection, and revision checks.
Callbacks read the current connection snapshot without cross-App fallback or a process-wide command cache.
Local changes affect new submissions. Accepted tasks retain their content.
Unknown or disabled commands return privately. Public roots omit the alias prefix.

Each App save exports, merges, validates, and synchronizes its manifest while preserving unrelated fields and commands.
It adds the commands bot scope when needed but never removes scopes.
If Slack already matches, prompt-only changes need no manifest update.
An existing command can be adopted only when its URL matches this deployment's callback. Other handlers cause conflicts.
Slack permits 50 commands across managed and unmanaged entries.

Each App selects a tenant credential profile. Profiles can share an account without copying refresh tokens.
Use separate profiles for different accounts. Enter a configuration refresh token, not a bot token, in the write-only form.
Never copy tokens across tenants or into external tools.
The deployment root seals credentials with a separate purpose and tenant/profile-bound associated data. Public projections never expose them.
Rotation persists both returned tokens before further Slack requests. If persistence fails after Slack consumes the token, replace it.
Refresh occurs near expiry on use, without a periodic worker.

A PostgreSQL session lock serializes admin operations and token rotation across nodes. Contention returns immediately.
Attempts use bounded timeouts without automatic HTTP retries. Rate limits show the retry interval.
Closing the page can interrupt synchronization. Reload and retry pending or failed attempts.
Possible published names survive ambiguous responses so later deletion can remove them.
Failures record the stage and outcome on the existing App configuration:
- Before update: this attempt sent no manifest update, including credential, validation, and local conflict failures.
- Known update rejection: Slack refused this attempt.
- Unknown update result or failed verification: Slack might have received the update.
Unknown provider errors remain unconfirmed, including [internal and fatal errors](https://docs.slack.dev/reference/methods/apps.manifest.update/), which can follow partial success.
Labels describe the latest attempt, not earlier attempts. Unclassified failures stay unconfirmed. Success clears failure classification.

Local save and Slack registration are not atomic. Deletion stops new local submissions before remote removal. Existing tasks continue.
Manifest synchronization does not prove execution. New permissions require OAuth reauthorization through the App link, then a synchronization retry.
Salix pushes App configuration. Slack does not query Salix for its slash menu.
Apps remain isolated in Salix, but duplicate names in one Slack workspace route to the most recently installed App.
Do not edit the manifest concurrently through Slack or another tool. The Manifest API replaces it without conditional writes.
Deleting or rebinding a Connect does not uninstall its old App. Remove aliases and confirm synchronization before retiring it.

## Triage collaboration

Triage batches input for its Worker, which owns research, context suggestions, and participation, including social and resolved threads.
Use Router-authorized reads for other channels and relevant linked threads before any decision, including silence.
A reply, preview, or promise does not prove correctness or resolution.
Correct consequential errors with reliable evidence. Stay silent when a correct, complete answer needs no addition.
Check useful next actions. Do not audit every exchange or duplicate owned investigations.
Unsolicited replies need more than agreement or paraphrase. Invited, specific humor is valid.
For silence, the Worker records `already_handled`, `no_useful_addition`, or `insufficient_evidence` as its `reason_code`.
A material unread source is insufficient evidence, not proof that the question is handled.
Code records assessments without independent verification or automatic retries. Historical uncoded silence stays unclassified.
After investigation, a help request for unresolved work must include an explicit `agent_owned` follow-up through `internal.triage.complete`.
Set and cite `follow_up_ref` to update an active follow-up. Identity, interval, and Schedule stay unchanged.
Reuse needs the same project, target, generation, and current source evidence. Invalid reuse creates nothing. Citations cannot merge goals.
Rechecks reuse their receipt’s entry. Only independent goals use `follow_up_action=create`, with completion evidence and interval.
Recheck active incidents after one hour, later for access or human availability. No new evidence means no repeated public request.
Only source-confirmed completion or cancellation resolves it. An open issue alone does not authorize reminders.
`TriageProductRuntime.supersede_follow_ups/3` accepts operator-selected duplicates and current snapshots of at most 20 entries in one Project, Agent, and target.
It retains payloads, the selected Schedule, and admitted work. Other entries become `superseded`, not resolved. Their old wakes admit no work.
Router stays silent. Do not restore Worker-return/Router-polish.

Group `triage_worker` owns Worker selection for intake and configuration.
Triage administrators with project-management permission select an available ordinary Worker in the same Swarm. It can perform other tasks.
Empty selection pauses intake. Intake cannot create or replace Workers. Existing assignments keep their Worker.
Only Triage configures assignment. Agents manages the Worker and links its usage badge to Triage.
Each change attempts an audit first. The binding keeps actor, request, previous Worker, and revision. A second row confirms success.
If confirmation fails, the page reports the applied change and incomplete audit.
Stale forms fail instead of overwriting a later selection.
Selection freezes with input. Accepted assignments and Tasks retain their Worker through delays and retries.
An archived Worker, unavailable external runtime, or failed preparation stops new intake with `triage_worker_unavailable`.
Triage cannot select a replacement or reactivate an archived Worker automatically.
Configuration filters at most 20 Agent records per page and reads at most two runtime statuses: selection and candidate preview.
Search and pagination are manual, without polling.
The Agents page reads one Group binding and resolves its Router record once per page. It marks the selected Worker as Used by Triage.
Before archive, BFT rechecks the binding. Its selected Worker requires confirmation of the current revision.
The dialog names the Swarm and links to Triage to select a replacement.
Confirmed archive keeps the binding, so new assignments stop without fallback. Existing tasks are not reassigned.
The ordinary Agent archive contract still stops execution and pauses Agent-owned schedules.
Confirmation is a preflight, not a selection/archive transaction. Intake still checks current Worker availability.
Plugin policy, Task scope, and runtime availability differ. Configuration does not prove model execution.
Ordinary assignment sends no model request, reply, or reaction and retains no context.
The frozen source and identity checks still apply. Task creation rechecks current project, Router, Worker, and source authority.
If the current source omits the sealed decision target, intake stops with `triage_source_target_unavailable`.
This failed run creates no Worker and makes no model request. It does not select a later message as a replacement target.
The result proves target unavailability, not deletion. A deletion claim requires separate source evidence.
The event cutoff stays fixed. Freshness retains timestamp and version for all frozen messages, including uncited messages outside the display summary.
For newly materialized ordinary domain-assigned intake, new messages do not stop Task creation. The Worker reads the current target thread before deciding.
Historical decisions, scheduled effects, and public results stop on unseen non-self messages after the cutoff, including messages before an observed source.
Edits or deletions of frozen messages, incomplete reads, and authority changes stop intake and public effects.
Unmarked immutable obligations retain the strict cutoff and their stored source authority.
Zero model requests at assignment do not prove provider observation or Worker execution.

After Worker command delivery exhausts its retry budget, the Participant retains a durable handoff before removing the delivery from recovery.
The Conversation owner marks the unchanged investigation `escalated` and records a private delivery warning, without invoking the Router.
This means delivery is unconfirmed, not that the Worker rejected the command. Accepted work retains its grant and can still complete normally.
Newer Task messages, a replaced Worker session, and a Task that already left `active` prevent stale escalation.
The handoff permits three attempts, including interrupted attempts. Persistent owner failure ends with `triage_command_settlement_unavailable` in the delivery diagnostic.
This bounded handoff adds no polling or scan. It does not repair historical terminal delivery records automatically.

Timeline reads at most 20 indexed memberships within budget. Fence status excludes input, proof, and ledger bodies.
Recorded completion is not verified evidence. Memberships and archived fences preserve completed status after active-history cleanup.
Missing or invalid archived status stays unavailable. Details validate one receipt's evidence within budget and current administrator/project access.
Failed details preserve list status and warn. Diagnostics load on request.

Batch details read at most two Tasks and 20 committed Messages each, with current administrator/project access checks.
Manual refresh replaces previews even on failure. Previews show the latest submitted Worker decision and silence classification from those Messages.
Task metadata supplies unconfirmed-delivery warnings without extra reads. Successful completion removes them.
Private Task status includes human review after success. Submission/completion proves neither source resolution nor public delivery.
New-input suppression does not prove replacement work. Verify the later Task's source reads and result separately.

The first provider-confirmed reply saves the original question, reply, and Task context for continuation.
Later follow-ups in that thread use the normal Router path and continue the same Task when appropriate.
A follow-up from another Slack app continues the thread the same way a person's does, as ordinary input.
It never carries command authority, and this Bridge's own messages never continue its thread.
Reaction or silence does not enable continuation.
A local model response is not provider confirmation.
Scheduled rechecks retain reminders. Historical committed obligations recover under their sealed contract.
Rechecks of one message retain separate sealed occurrences. Effect cutoffs contain each timestamp once.

Batch freeze and Worker assignment tests do not establish final answer quality or delivery.
Validate real continuation, duplicate ingress, restart, stale Worker results, and provider failures separately.
Do not claim all scenario quality from the engine's pre-Worker local cases.

## Slack history and search

Callback and Triage share the current message's recipient extraction.
A terminal text `*Sent using* <@ID>` names a sending tool, not a recipient.
Only that occurrence is excluded. Body mentions and rich-text user nodes still contribute, including the same ID.
Text containing backticks or a final quoted line retains all mentions because the attribution is ambiguous.
The original source remains unchanged. Attribution alone means no syntactic recipient, not permission or verified tool identity.

Slack source history, current installation authority, Triage admission, and search publication are separate owners.
A historical channel projection cannot authorize a current read after installation or membership changes.
Patrol suspends a cursor when the provider confirms that its channel authority is ineligible.
Suspension preserves its scan checkpoint, receipts, and channel settings. It does not authorize or rejoin a Slack channel.
The existing bounded discovery pass resumes the cursor only after the provider confirms current authority.
The same authority resumes from the saved checkpoint. A changed authority retains the existing tail-start rule.
Temporary provider or storage failures remain retryable. Inactive cursors do not enter the due-claim queue.
The Message-search return path rechecks source identity, publication, and current connection facts before reading snippets.
See [Storage and search](../storage-search.md).

An onboarding progress indicator must represent the actual durable stage.
Do not label an accepted setup request as completed history import or working bot delivery.
After connection, verify a real bounded message flow and the corresponding runtime outcome.
Do not scan every historical thread on an interactive status request.

## Feishu

Dashboard SSO and bot-message routing are separate setup workflows.
Organization Settings stores the app ID and secret once.
Select that binding for login or bot messaging as appropriate.
Selecting Feishu SSO replaces the organization's other active SSO provider.
Membership still controls organization and Project access.
See [Identity and security](../identity-security.md).

For a bot connection, verify the selected app, published permissions, installation, callback configuration, and Group routing.
Use the product's displayed callback/redirect values instead of copying an environment URL from an old runbook.
Provider-console permissions can change. Check the current console before an operational setup.
Never paste app secrets into a support thread or screenshot.

## Runner and devices

BFT enrolls organization machines and controls which Projects can select them.
The runner starts a separate Salix Connector for each Project Group.
A provision request is progress, not stable runtime identity.
Use [Compute and devices](../compute-devices.md) for IDs, reconnect, and launchd boundaries.
System launchd recovery is an administrator action through the fixed Agent VMM
service executor. BFT passes only the `runner` job selector. It does not pass a
label, plist, program path, environment, or UID. After the job starts, managed
repair runs as the non-root service user and can restart the existing VM and
reconcile only the selected registration with one stable request ID.

## Subscription settings

A tenant-private template belongs to the organization's Salix tenant.
Apply the BFT organization allowlist after the tenant-visible catalog.
An empty allowlist permits that catalog. A nonempty allowlist restricts both global and private templates.
Do not expose another tenant's configuration or platform credentials.
Template deletion retains the owner's bounded reference checks and does not delete Agents or history.
See [Billing and models](../billing-models.md).

## Operations

Diagnose product admission first, then canonical execution, then provider delivery.
Correlate inbound, provider request/response, tool execution, and visible reply using the encrypted archive.
Never use plaintext archive mailboxes or weaken runtime seam guards for a quieter test suite.
See [Observability](../observability.md) and [Release operations](../release-operations.md).

For an installed managed compute node, use `bft compute-node status --json`.
The formal Host bundle provides the versioned `agent-vmm` contract. It includes
inspect, diagnose, bounded logs, operation get/follow, VM actions, repair,
update, and cleanup preview/execute. Supply BFT-owned registration,
environment, and workload identifiers explicitly.
Local VMM health does not prove a runner heartbeat, Server admission,
authentication, or completed work.

VM start and stop use the Host lifecycle owner and one stable request ID. The
Host acquires that owner before it records acceptance. Client cancellation does
not cancel accepted work. An untyped transport failure is an unknown outcome,
so BFT retries only the same request ID. A typed pre-admission rejection permits
a new request after the competing action is resolved. An interrupted result
requires current VM inspection before BFT creates a new request.

The runner invokes managed Host update only for a login-agent installation. It
passes the Server-selected release ID, exact HTTPS URL, SHA-256, byte size, and
a stable request ID. A daemon target produces
`agent_vmm_administrator_update_required`; the runner does not download the
artifact or invoke `sudo`. The administrator installer uses the fixed service
executor for the Host job and runs lifecycle and VM work as the non-root
service user. After replacement, recovery moves forward with the same request;
the previous binary is not a rollback target.
