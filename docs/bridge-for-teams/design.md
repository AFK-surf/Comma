# Bridge For Teams

## Product boundary

BFT owns users, organizations, Projects, membership, setup, and product navigation.
A Project maps one-to-one to a Salix Group.
Salix owns execution identity, Conversations, Participants, device facts, and runtime dispatch.
Web and CLI use the same product API and authorization boundary. A dashboard projection is not a second runtime authority.

Generated PDFs and screenshots belong outside the tracked docs inventory.

## Slack Task commands

`/newgpttask <text>` submits `Create a task using a Codex worker. Task content: <text>` to the connected Group's Router.
`/newclaudetask <text>` submits `Create a task using a Claude worker. Task content: <text>` to the same Router.
Normal Task admission and worker availability still apply.
The public endpoint `POST /v1/im/slack/commands` verifies the Slack signature, App, and workspace before delivery.
One `conversations.info` read with the connected bot token then checks access. Commands require channel membership or an accessible bot DM.
An inaccessible channel returns a private invitation prompt before Router delivery. Archived channels, missing read scopes, and failed checks return private repair or retry guidance.
Channel checks use 500 ms phase timeouts. The whole callback has one 2.5-second deadline.
This check does not prove that later replies can post.
The trigger ID supplies the inbox deduplication key. Empty input returns a private usage message.
The bot publishes attributed user input first. Router replies and Task cards use that thread. Success returns an empty ACK.

### Admin-managed aliases

Salix Admin, Slack commands, manages aliases for the selected organization's App. IM Connect owns each App's commands and synchronization state.
An alias has a name, description, usage hint, literal prompt prefix, and enabled flag.
The callback appends user input to the prefix, so include a separator. Router authorization and admission still apply.
New Apps have no aliases.
Tenant configs own organization presets. New catalogs start empty. System presets are separate.
Selecting a preset fills an editable draft. Publishing saves independent App values without inheritance.
Template changes never update Apps or Slack. Copies reject name conflicts and stale revisions.
Templates never cross tenants. App rebinding resets local aliases.

Only the authenticated admin dashboard exposes mutation, with tenant, connection, and revision checks.
Callbacks read the current connection snapshot without cross-App fallback or a process-wide command cache.
Local changes affect new submissions. Accepted tasks keep their content.
Unknown or disabled commands return privately. Public roots omit the alias prefix.

Each App save exports, merges, validates, and synchronizes its manifest. It keeps unrelated fields and commands.
It adds the commands bot scope when needed but never removes scopes.
If Slack already matches, prompt-only changes need no manifest update.
Salix adopts an existing command only when its URL matches this deployment's callback. Other handlers cause conflicts.
Slack permits 50 commands across managed and unmanaged entries.

Each App selects a tenant credential profile. Profiles can share an account without copying refresh tokens. Use separate profiles for different accounts.
Enter a configuration refresh token, not a bot token, in the write-only form.
Never copy tokens across tenants or into external tools.
The deployment root seals credentials with a separate purpose and tenant/profile-bound associated data. Public projections never expose them.
Rotation persists both returned tokens before further Slack requests. If persistence fails after Slack consumes the token, replace it.
Refresh occurs near expiry on use, without a periodic worker.

Attempts use bounded timeouts without automatic HTTP retries. Rate limits show the retry interval.
Closing the page can interrupt synchronization. Reload and retry pending or failed attempts.
Possible published names survive ambiguous responses so later deletion can remove them.
Failures record the stage and outcome of the latest attempt on the App configuration:
- Before update: this attempt sent no manifest update.
- Known update rejection: Slack refused this attempt.
- Unknown update result or failed verification: Slack might have received the update.

Unknown provider errors stay unconfirmed, including [internal and fatal errors](https://docs.slack.dev/reference/methods/apps.manifest.update/), which can follow partial success. Success clears failure classification.

Local save and Slack registration are not atomic. Deletion stops new local submissions before remote removal. Existing tasks continue.
New permissions require OAuth reauthorization through the App link, then a synchronization retry.
Salix pushes App configuration. Slack does not query Salix for its slash menu.
Duplicate names in one Slack workspace route to the most recently installed App.
Do not edit the manifest concurrently through Slack or another tool. The Manifest API replaces it without conditional writes.
Deleting or rebinding a Connect does not uninstall its old App. Remove aliases and confirm synchronization before you retire it.

## Triage collaboration

Triage batches input for its Worker. The Worker owns research, context suggestions, and participation, including social and resolved threads.
Use Router-authorized reads for other channels and relevant linked threads before any decision, including silence.
A reply, preview, or promise does not prove correctness or resolution.
Correct consequential errors with reliable evidence. Stay silent when a correct, complete answer needs no addition.
Check useful next actions. Do not audit every exchange or duplicate owned investigations.
Unsolicited replies need more than agreement or paraphrase. Invited, specific humor is valid.
For silence, the Worker records `already_handled`, `no_useful_addition`, or `insufficient_evidence` as its `reason_code`.
A material unread source is insufficient evidence, not proof that the question is handled.
Code records assessments without verification or automatic retries.

After investigation, a help request for unresolved work must include an explicit `agent_owned` follow-up through `internal.triage.complete`.
Set and cite `follow_up_ref` to update an active follow-up. Identity, interval, and Schedule stay unchanged.
Reuse needs the same project, target, generation, and current source evidence. Invalid reuse creates nothing. Citations cannot merge goals.
Rechecks reuse their receipt's entry. Only independent goals use `follow_up_action=create`, with completion evidence and interval.
Recheck active incidents after one hour, later for access or human availability. No new evidence means no repeated public request.
Only source-confirmed completion or cancellation resolves a follow-up. An open issue alone does not authorize reminders.
`TriageProductRuntime.supersede_follow_ups/3` accepts operator-selected duplicates and current snapshots of at most 20 entries in one Project, Agent, and target.
It keeps payloads, the selected Schedule, and admitted work. Other entries become `superseded`, not resolved. Their old wakes admit no work.
Router stays silent. Do not restore Worker-return/Router-polish.

Group `triage_worker` owns Worker selection for intake and configuration.
Triage administrators with project-management permission select an available ordinary Worker in the same Swarm. That Worker can also do other tasks.
Empty selection pauses intake. Intake cannot create or replace Workers. Existing assignments keep their Worker.
Only Triage configures assignment. Agents manages the Worker and links its usage badge to Triage.
Each change attempts an audit first. The binding keeps actor, request, previous Worker, and revision. A second row confirms success.
If confirmation fails, the page reports the applied change and incomplete audit.
Stale forms fail instead of overwriting a later selection.
Selection freezes with input. Accepted assignments and Tasks keep their Worker through delays and retries.
An archived Worker or failed preparation stops new intake with `triage_worker_unavailable`. Triage cannot select a replacement or reactivate an archived Worker automatically.
Configuration filters at most 20 Agent records per page and reads at most two runtime statuses. Search and pagination are manual, without polling.
The Agents page marks the selected Worker as Used by Triage.
Before archive, BFT rechecks the binding. Archive of the selected Worker requires confirmation of the current revision.
The dialog names the Swarm and links to Triage to select a replacement.
Confirmed archive keeps the binding, so new assignments stop without fallback. Existing tasks are not reassigned.
The ordinary Agent archive contract still stops execution and pauses Agent-owned schedules.
Confirmation is a preflight, not a transaction. Intake still checks current Worker availability.
Configuration does not prove model execution.
Ordinary assignment sends no model request, reply, or reaction and keeps no context.

Task creation rechecks current project, Router, Worker, and source authority.
The decision and Task target is the newest batch message in the source.
It skips a newer batch message only if the mirror marks it deleted. If all are deleted, the run is `skipped_source_deleted`.
Otherwise intake stops with `triage_source_target_unavailable`: no Worker, model request, or replacement target.
The event cutoff stays fixed. Freshness keeps timestamp and version for all frozen messages, including uncited ones.
For newly materialized ordinary domain-assigned intake, new messages do not stop Task creation. The Worker reads the current target thread before it decides.
Historical decisions, scheduled effects, and public results stop on unseen non-self messages after the cutoff.
Edits or deletions of frozen messages, incomplete reads, and authority changes stop intake and public effects.
Owner decision: receipts and the reader rewrite `Bearer <value>` in text and filenames to `[Bearer-credential withheld]` before hashing.
Spans with another credential, memory, and other credentials reject. ClickHouse rows and old receipts keep raw text.
Unmarked immutable obligations keep the strict cutoff and their stored source authority.

See [Conversation log consumption](../salix/conversation-owner-actor.md#conversation-log-consumption) for terminal Worker command escalation, retry, and recovery.

Batch details read at most two Tasks and 20 committed Messages each, with current administrator and project access checks.
Manual refresh replaces previews even on failure. Previews show the latest submitted Worker decision and silence classification.
Task metadata supplies unconfirmed-delivery warnings. Successful completion removes them.
Submission or completion proves neither source resolution nor public delivery.
New-input suppression does not prove replacement work. Verify the later Task's source reads and result separately.

Pre-Worker batch tests do not prove answer quality, delivery, continuation, duplicate ingress, restart, stale results, or provider failure.
Owner decision: drain releases pre-transport runs ([see](../../tla/salix/README.md)).

## Slack history and search

Slack source history, current installation authority, Triage admission, and search publication are separate owners.
A historical channel projection cannot authorize a current read after installation or membership changes.
Patrol suspends a cursor when the provider confirms that its channel authority is ineligible.
Suspension keeps its scan checkpoint, receipts, and channel settings. It does not authorize or rejoin a Slack channel.
Discovery resumes the cursor only after the provider confirms current authority.
The same authority resumes from the saved checkpoint. A changed authority uses the tail-start rule.
Temporary provider or storage failures stay retryable. Inactive cursors do not enter the due-claim queue.
The Message-search path rechecks source identity, publication, and current connection facts before it reads snippets.
See [Storage and search](../storage-search.md).

An onboarding progress indicator must show the actual durable stage.
Do not label an accepted setup request as completed history import or working bot delivery.
After connection, verify a real bounded message flow and its runtime outcome.
Do not scan every historical thread on an interactive status request.

## Feishu

Dashboard SSO and bot-message routing are separate setup workflows.
Organization Settings stores the app ID and secret once. Select that binding for login or bot messaging.
Selecting Feishu SSO replaces the organization's other active SSO provider. Membership still controls organization and Project access.
See [Identity and security](../identity-security.md).

For a bot connection, verify the selected app, published permissions, installation, callback configuration, and Group routing.
Use the callback and redirect values that the product shows. Check the current provider console before setup.
Never paste app secrets into a support thread or screenshot.

The bot reads documents and Minutes as the app. Meetings, their AI notes, transcripts and recordings are shown only to people, so people of an Agent Swarm sign in with their Feishu account under Connections → Accounts.
The organization's OAuth app for `feishu` is the organization's Feishu app, with the redirect URL the dialog shows and the user scopes of the "SSO + group bot" import (`BridgeForTeams.FeishuScopes.sign_in_user_scopes/0`).
A swarm holds any number of signed-in people. `feishu.search_meetings`, `feishu.get_meeting` and `feishu.get_note` run as every active account, or as the one named by `account`; document and Minutes reads with `account` run as that person.

## Runner and devices

BFT enrolls organization machines and controls which Projects can select them.
The runner starts a separate Salix Connector for each Project Group.
A provision request is progress, not stable runtime identity.
Use [Compute and devices](../compute-devices.md) for IDs, reconnect, and launchd boundaries.
System launchd recovery is an administrator action through the fixed Agent VMM service executor.
BFT passes only the `runner` job selector. It does not pass a label, plist, program path, environment, or UID.
Managed repair runs as the non-root service user. It can restart the existing VM and reconcile only the selected registration with one stable request ID.

## Model settings

An Agent model is a Salix model choice. Without one, the Agent follows the platform model of its role.
Allowed models limit admin choices. An empty list allows every model.
The AI models page groups the catalog by what serves each model for the org: a subscription plan, pay-per-use Provider API keys, or no account.
Pay-per-use (`allow_paid` true) is a separate choice for the allowed list and the defaults. It names the key sources that can serve it, and the account pool picks one.
Models that no account serves stay hidden until requested and cannot be newly allowed. An account change reloads what serves each model.
A new Router or internal Worker gets a copy of the org default for its role. An empty default follows the platform.
Salix checks choices in the org tenant. Only that tenant's Profiles serve a catalog model. Never expose other tenants' credentials.
See [Billing and models](../billing-models.md).

## Operations

Diagnose product admission first, then canonical execution, then provider delivery.
Correlate inbound, provider request/response, tool execution, and visible reply with the encrypted archive.
Never use plaintext archive mailboxes or weaken runtime seam guards for a quieter test suite.
See [Observability](../observability.md) and [Release operations](../release-operations.md).

For an installed managed compute node, use `bft compute-node status --json`.
The Host bundle provides the versioned `agent-vmm` contract: inspect, diagnose, bounded logs, operation get/follow, VM actions, repair, update, and cleanup preview/execute.
Supply BFT-owned registration, environment, and workload identifiers explicitly.
Local VMM health does not prove a runner heartbeat, Server admission, authentication, or completed work.

VM start and stop use the Host lifecycle owner and one stable request ID. The Host acquires that owner before it records acceptance.
Client cancellation does not cancel accepted work.
An untyped transport failure is an unknown outcome, so BFT retries only the same request ID.
A typed pre-admission rejection permits a new request after the competing action is resolved.
An interrupted result requires current VM inspection before BFT creates a new request.

The runner invokes managed Host update only for a login-agent installation. It passes the Server-selected release ID, exact HTTPS URL, SHA-256, byte size, and a stable request ID.
A daemon target produces `agent_vmm_administrator_update_required`. The runner does not download the artifact or invoke `sudo`.
The administrator installer uses the fixed service executor for the Host job and runs lifecycle and VM work as the non-root service user.
After replacement, recovery moves forward with the same request. The previous binary is not a rollback target.
