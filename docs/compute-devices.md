# Compute and devices

## Ownership

Comma Workspaces and BFT Projects use Salix Groups. Products own setup and member access.
Salix owns devices, runtimes and dispatch. Check membership and scope before connecting. Scope machine credentials to Groups.

## Execution environments

Tasks use a Station on user/Group hardware (a computer or VMM Station) or a managed Sandbox ([below](#coding-sandboxes)).
Durable data lives in Salix (Task Messages, accounts), VFS, Drive and pushed branches; a sandbox disk is a cache.
Cloudflare Cloud VMs (one per Group) retire by owner decision; their contract stays until then. VMM Stations remain.

## Identity

Device identity is Group-scoped. `connector_id` identifies installation. Reconnect changes `connector_run_id`.
`environment_id` selects commands, files, and processes. `device_runtime_id` identifies a discovered runtime. BFT `runner_id` identifies enrollment, not dispatch.
Dispatch resolves runs. Aliases cannot select targets. PID/port/socket/run IDs route requests.
External Sessions are retired. Workers bind to a station. Stored External Sessions stay read-only ([Retired Sessions](architecture/DOMAIN_CONCEPTS.md#retired-sessions)).
See the [domain inventory](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute).

## Installation and Runner

Tools and installation `connector-token` need no SSH/Drive. Consent grants read-only access until reboot, with no startup service.
First Station registration expires after 15 minutes; reconnect does not. Revocation persists. VMM uses the claim contract below.
The requesting member owns the install command and Device (`owner_user_id`), and sets access in Settings > Devices.
Reuse uncertain commands. Verify `connection-check.txt` through the exact Device/Environment.
Runners use BFT device-code auth. Group Connectors use Salix credentials, without BFT login.
Reconnect updates routes and fences stale runs. Manager loss or upgrade cannot stop independent workloads. Reject unsupported operations locally.
Station cutover: [Station](architecture/DOMAIN_CONCEPTS.md#station).

## Comma desktop machine accounts

Desktop stations never auto-import CLI logins. Settings > Devices lists this computer's Codex and Claude Code CLIs:
a usable login shows a switch, an unsigned or keychain-only one shows sign-in.

The switch controls its `machine-<runtime>` station profile. Only the computer owner can change it or sign in; without an owner, Workspace owners and admins can.
`POST /machine-logins` runs `claude auth login` or `codex login` in the person's home; the CLI gets approval on its local callback, and credentials stay in a profile-readable file.
Success refreshes inventory and enables the profile; `machineSignIns` reports results and why a login went unused.

Remotely only the owner sets a source, only to `local`, via a question card ([account source](architecture/DOMAIN_CONCEPTS.md#station)).

Profile removal blocks later turns, warm ones too. Sent turns can finish.
Other profiles, credentials and history remain. Restart or refresh enables no removed account.
Upgrades keep enabled profiles. Cloud VM controls differ.

The page reads this station on entry/focus, one request per edit; an uncertain reply causes one local read, never other-device polls.

## Compute and VMM

Project/Swarm/Group owns Compute Environments; Device access is separate. Bound offline requests. Input awaits READY. Recovery repairs hints without Session polls.
Preserve bindings, accepted input, tool deadlines and receipts. Explicit targets and accepted work keep their selected machine.
See [deadlines](agent-runtime.md).
VMM gateway secrets are separate from [Comma secrets](release-operations.md).
VMM Host and user Device disk disposal needs owner approval; Cloudflare Group VMs follow the policy below.
Compute uses [billing facts](billing-models.md), not delayed usage telemetry.

Authorized Worker selection wakes archived Cloudflare Workloads with a 30s demand hold.
A ready Group VM archives after `idle_archive_ms` (5 minutes) with no Salix operation, no agent settle after one, and no Task Message its station posted or was given. A station that refuses to park waits the idle period again, doubled per refusal in a row, at most four times, until the VM is used again.
See [Tasks](../systems/station/docs/tasks.md) for station wake when Salix cannot give a Task Message to an unconnected Group VM station.

Shell Host tunnels keep their gRPC connection while idle, until session expiry, revocation, or transport loss; a Host request that finds the tunnel gone marks the current session stale and its ready Workload pending.
[Compute reconciliation](architecture/DOMAIN_CONCEPTS.md#group-compute-lifecycle) replaces missing, stale, or expired shell sessions.
Discovery reports observed state without a Host probe and does not guarantee current execution availability.

Storage-headroom failures pause preparation, unknown-outcome admissions included; freeing capacity does not retry. Retry keeps Allocation, generation, limits and command evidence. Members retry Shells and the Group Station; a Host reconnect reopens a Group Station parked on a failed or unknown command.

Cleanup and renewal: [settings](product-features.md#compute-node-settings-and-initialization).

### Linux Compute Host installation

Get the Linux command in Cue Settings > Devices or BFT Project Compute. Linux arm64 needs sudo, systemd and KVM. The server fixes the Group; no desktop app or separate login is needed.

The script POSTs the ticket in the body and runs the Host bundle. Native owns systemd and recovery; downloads keep the ticket.
The Host saves its credential before one claim consumes a 15-minute ticket. The server stores its hash.
A lost reply repeats the same claim, subject to current authorization. Ticket cleanup keeps request idempotency.
BFT permits one live Host per stable Project. Credential loss requires current product permission and original-root proof on the same Registration.
See [settings](product-features.md#compute-node-settings-and-initialization) for renewal, revocation and recovery.

## Automatic Station placement

Each authorized Registration prepares a VMM Station. New configurations use `tools.access=full`; existing settings stay.
Automatic Tasks prefer VMM, the requester's authorized physical Station, then enabled Cloudflare. Receipts keep targets on retry.
Managed Stations use cloud-authorized profiles; physical logins require owner opt-in.
A Router Task for one of several computers needs the person's word.

## Cloud VM data policy

Cloudflare Group VM disks are disposable, including edits, dependencies, native history, and local auth.
Archive and restore are best effort; after bounded recovery fails, rebuild the exact VM. Disk loss needs no approval and blocks no release.
A Container's disk lives only as long as the Container. Salix never starts a ready VM's stopped Container empty: it seals the Gateway control and releases the Container, as an archive does, so the VM is `archived` with its last archive and wakes from it.
Salix never archives a stopped Container; with no archive the VM starts empty and its record keeps `container_loss`.
A wake's Container restores the archive before its station starts; if it cannot, it exits and no station connects.
An archive is the Container's whole `/workspace` tree: the station data directory `/workspace/.comma/station` and the home `/workspace/.salix/sprite-home` (`/home/sprite` links to it).
It leaves out live database files (snapshots travel instead), `run/` runtime state (a restore drops it), runtime homes' `.tmp`, regenerable caches under the home (`.cache`, `.npm/_cacache`, `.codex/tmp`, package-manager stores), and links out of `/workspace`.
Each Task's Session starts with its own empty workspace under `/workspace/.comma/station/sessions/`, kept until that Session is deleted.
`HOME` is the archived `/home/sprite/.local/share/salix/connector-home` (`.codex`, `.claude` too); restored entries get new timestamps at wake.
`pip install --user` (`PYTHONUSERBASE=/home/sprite/.local`, outside `HOME`) and `npm install --global --prefix /home/sprite/.local` land under the archived `/workspace/.salix/sprite-home/.local` and survive.
Nothing outside `/workspace` survives a wake, e.g. `npm install --global` without `--prefix` (`/usr/local`).

Preserve Salix-owned Sessions, Messages, queues, credentials, and execution records.
Never replay unknown effects or restore old pending execution after reset. Fence commands and confirm the exact carrier stopped.
Keep usable archives and report interrupted work or required login. Use Workload owner operations, never direct database edits.
Finish the generation-aware Comma rollout before reset. Do not restore an older serving binary afterward.
A reset advances the Workload generation. Sessions keep input with an unknown outcome and never replay it.

## Coding sandboxes

A sandbox Task (`runs_on {kind: sandbox}`) has its own L4ES VM. Coding Tasks add `repo {owner, name, base_ref?, branch?}`. Use them for GitHub work that needs no named machine or local files. Tasks without `repo` have no checkout, GitHub grant, git identity, diff or pull request.
Other places and retries reject `repo`. A sandbox-bound Worker's Tasks each take a live-sandbox slot and need configured sandboxes.

`SalixWeb.CodingSandboxes` owns lifecycle and turn `facts`. `SalixStore.CodingSandboxes` stores them on the Workload.
Group Stations and Task sandboxes share execution and connection authorization. Disk/resource policies differ.

- Identity: the Task owns an Environment on the tenant's `l4es` Pool, a ProviderBinding, and a `coding_sandbox` Workload.
  Each run gets an Allocation and advances the Environment and Workload generation.
  Device `dev-sbx-<task>` is stable. Commands, credentials, account profiles and the platform model need the current authorized Workload connection; old-generation and terminal connections get none.
- Creation: placement checks a coding Task's repository through the Group's GitHub binding, and the live-sandbox limit: the Workspace's admin override or `SALIX_L4ES_MAX_SANDBOXES` (default 5).
  A `starting` Workload reserves the sandbox. Creation uses `SALIX_L4ES_IMAGE`, node labels `SALIX_L4ES_LABELS` (none yet), its connect credential and, for coding Tasks, a GitHub grant and the owner's git identity.
  Its Station connects, accepts the Task and checks out a coding Task's branch before the first turn.
- Calls: L4ES takes a 300-second assertion from `CommaWeb.Coding.L4ESAssertions`. Before a create or terminal, Salix makes non-viewers L4ES members, who sign in with Comma.
- Checks: each node takes at most 20 Workloads per 15 seconds, with a 2-minute lease. Ready ones: each 5 minutes.
  A turn without follow-up puts the Task in review; a follow-up makes it active. The sandbox stops after 3 idle minutes in review or ended, else 2 hours, even with local work.
  Idle shutdown reports unpublished work. Neither it nor turn completion commits or pushes.
  5 minutes with no heartbeat, or no Task status read after a wake, makes it `failed`. A sandbox L4ES no longer runs is `lost`; an active Task gets one notice.
- Recovery: a Message resumes a `stopped`, `lost`, `failed` or `ended` sandbox, unless the Task ended: the Router answers. So does a reopen with an unanswered Message. Not a notice, event, or Message in a failed start. L4ES starts it from its disk.
  A refused start (409), or one pending on its disk 150 s after the start, is remade on a new disk unless still stopping; Task is told.
  Replacement waits until L4ES says the old run stopped. An unknown invite or stop result authorizes no second carrier.
  A new Station resumes from the pushed branch.
- Completion: completed, cancelled, failed and archived Tasks end their sandbox. Failed stops retry each minute by name.
- GitHub (coding Tasks): L4ES holds and Salix renews the token. Initial grants allow repo-wide reads and Task-branch writes. See [Router ACL updates](architecture/DOMAIN_CONCEPTS.md#coding-sandboxes).
  The agent controls Git writes. Explicit PR creation pushes commits. Mini App deployment also commits.
- Accounts: a selected `account_id` limits subscription profiles to that account, also when lookup fails.
- Billing: a start needs the Workspace's credits; VM time is metered ([billing](billing-models.md#sandbox-starts)).
- Tools: its Session calls Salix as the Worker ([agent runtime](agent-runtime.md#tool-calls-from-a-tasks-station)).

Sandbox disks are unarchived; L4ES can evict stopped ones.

Session state, changes, history, token use, PRs and terminals use `/v1/comma/workspaces/:id/coding`.
Deployment and image: [L4ES sandboxes](../systems/DEPLOYMENT.md#l4es-sandboxes).

## Managed runtime credential binding

Accounts: Device/Workload Codex/Claude OAuth. Claude/Compute pi API keys.
Codex needs Server admission per resume. Bindings hold account references. Workload bindings survive replacement.

Subscriptions own accounts. API keys store encrypted keys, bounded HTTPS endpoints, protocol/auth scheme. Public views omit keys. Connection/key changes or deletion require zero bindings. Renaming does not. Disabling requests revocation, without offline/upstream proof.

BFT GET/PUT/DELETE: `/dashboard/orgs/:org/projects/:project/workloads/:id/managed-auth`; device targets replace `workloads/:id` with `devices/:device_id/runtimes/:runtime_id`.
Salix: tenant-admin Account action. Tenant-key GET/PUT/DELETE `/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/managed-auth`. No Group/Connector-token access.
Unready runtimes can bind. Device bind/retry delivers then probes. Delivery does not prove readiness. Selection is per runtime.
BFT reads require project access. Writes require org admin/owner and project write. Readers get source/state/provider/issue. Configurers get public accounts/snapshots. Use `no-store`. GET never retries.

Codex external tokens replace process auth, preserving native login storage.
AccountPool refreshes within 5m of expiry or after rejection. Versioned claims prevent duplicates.
Pi uses a managed directory and secret-free model projection. Claude gets one auth variable in its child environment.
Claude OAuth uses `CLAUDE_CODE_OAUTH_TOKEN`. AccountPool keeps refresh tokens. API keys supply the endpoint.
Both reject credential conflicts. No keys in auth files, managed/public views, argv, durable queues, or Salix logs.
Connector/native process/extensions/tools/host can read secrets.

Delivery rechecks Device connection or Compute Workload/RuntimeInstance/allocation/execution generation/epoch/VMM Host.
`runtime.subscription.v1` negotiates support. Sync is token-free.
CIRCL HPKE: fresh keys/nonces, P-256/HKDF-SHA256/AES-128-GCM.
AAD binds tenant/project/Workload/RuntimeInstance/generation/epoch/nonce. Ciphertext protects relays/logs, not compromised runtimes.
Compute: two pulls/socket, ≤11s each.

Device Codex switches accounts directly. Compute/Claude require confirmed unbind before rebind.
Stop issuance. Delete only after the exact revoked-revision ACK.
Revocation interrupts managed processes, preserving Sessions. Offline revocation waits for reconnect/upstream action.

## Host reconnect and Runtime recovery

Host Registration epochs fence routes. RuntimeInstance epochs fence execution.
Creation fences allocation generation/execution/container instance. Dispatch checks route/state/generations/credentials/epochs.
Reconnect keeps generation. Resume needs fresh inventory and keeps consumed bootstrap/in-flight identity. Ready/retained reports preserve actual release obligations, not a prior Host admission state. Release/revoke retires authority.
Late bootstrap cannot change epochs. Pending input alone can change execution epoch. In-flight input blocks replacement.

Bootstrap expiry repairs only never-authenticated execution. Otherwise use runtime credentials.
Repair requires quiesce and exact-instance stop. Stop/delete request IDs include instance/container generation.
Fresh stopped inventory commits Allocation facts and ready→pending Workload together. Volumes remain.
New Start identity uses container generation and last successful Start instance. Retries keep it.
Unknown outcomes preserve target and accepted input. Meeting bootstrap/in-flight rules apply.

Host Session commit wakes its Workload without stealing claims. Container proof permits credential reuse.
Sweeps repair missed wakes. Readiness clears the deadline. Manual retry preserves age. Gateway errors omit private metadata and use finite reasons.
The owner recovers exited loops. Preserve children, credentials, volumes, and accepted work. Verify a task response.

VMM migrations preserve identity, credentials, volumes, and receipts. Failed migrations may reset under the recovery policy.
[Cutover and migration rules](../systems/connector/README.md).
Missing or contradictory inventory fails closed within budget.
A Host hello drops unknown or contradictory inventory entries instead of failing. Epoch and generation fences stay.

## Mac apps on a member's Mac

The `mac-apps` plugin binds MCP `mac` to one member's Mac: `placement: device`, the device's Connector runtime, and `owner_user_id`. Comma for Mac lists it and installs it with the device ID. Each app starts off. The member enables it. See [Mac apps plugin](architecture/DOMAIN_CONCEPTS.md#mac-apps-plugin).
Salix sends each JSON-RPC message with the Connector method `client_mcp` (`server: "mac-apps"`). The station forwards it to Main with Main's bearer. A device with Read access accepts it; Off refuses it like a read. No device port, URL or token reaches Salix.
Main serves only the apps the user turned on. That Mac owns the switches for all connected workspaces. A change installs the plugin again, which rediscovers the tools. Uninstall removes the workspace's binding and leaves the switches.
MacAppsHost runs the tools as Comma's child, so macOS attributes permissions to Comma. A call without a permission returns `permission_required` and never prompts. Only the user's switch in Comma requests a permission: turning Vision on also takes one screen capture, so macOS asks then whether Comma may capture without its window picker. An app opened only for its Automation prompt is closed again. Comma does not read Messages history: that needs Full Disk Access, which every command its station runs would share. A switch macOS did not allow stays off, and Plugins says so. macOS reads Screen Recording into a process when it starts. After the user goes to System Settings for it, Main starts a new MacAppsHost when it reads the state, while no call runs, for up to 10 minutes or until the grant shows. The user does not restart Comma.
A `client:` binding runs only when the turn's requester owns the device it reaches, as the device registry records; no binding field decides. A Worker's turn in an ordinary one-shot Task counts as the person whose own Router message created the Task, for the Task's first command only. A later command the Router sends into the Task, background work, schedule fires, Loop wakes, scheduled and Loop Tasks, and other members get an error. An Agent's `mcp_manager` cannot create or change such a binding. Only Comma's own MCP definition may use the `comma-client` transport: Salix refuses it in any other definition. Results keep the Group connector label.
An offline Mac returns `device_offline`. Calls are not queued or replayed. A write that times out has an unknown outcome, and the error says so. MacAppsHost does not start an AppleScript call whose deadline passed while it waited for the main thread. The station aborts a request Main has not answered in 30 seconds. A change to a recurring event must name its occurrence (`occurrence_start`).
Calendar, reminder, note, contact, and place results include up to five `mac_app_item` reply cards. Comma on a Mac draws each as its app does and opens the item there; other clients show text.
