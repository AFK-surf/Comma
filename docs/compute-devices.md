# Compute and devices

## Ownership

Comma Workspaces and BFT Projects use Salix Groups. Products own setup and member access.
Salix owns devices, runtimes and dispatch. Check membership and scope before connecting. Scope machine credentials to Groups.

## Execution environments

Two kinds serve Tasks: a Station on the user's or Group's own hardware (a personal computer, or a VMM Station on a Group Host) and a Sandbox the platform manages (an L4ES VM for one Task, [below](#coding-sandboxes)).
Durable data lives in Salix (Task Messages, accounts), VFS, Drive and pushed branches; a sandbox disk is a cache.
By owner decision the Cloudflare Cloud VM (one long-lived VM per Group) retires in a later release; its contract below stands until then. The Group VM on an Agent VMM Host stays as a VMM Station.

## Identity

Device identity is Group-scoped. `connector_id` identifies installation. Reconnect changes `connector_run_id`.
`environment_id` selects commands, files, and processes. `device_runtime_id` identifies a discovered runtime. BFT `runner_id` identifies enrollment, not dispatch.
Dispatch resolves runs. Aliases cannot select targets. PID/port/socket/run IDs route requests.
External Sessions are retired. Workers bind to a station. Stored External Sessions stay read-only ([Retired Sessions](architecture/DOMAIN_CONCEPTS.md#retired-sessions)).
See the [domain inventory](architecture/DOMAIN_CONCEPTS.md#7-devices-and-compute).

## Installation and Runner

Tools and installation `connector-token` need no SSH/Drive. Consent grants read-only access until reboot, with no startup service.
First registration expires after 15 minutes; reconnect does not. Revocation persists.
An install command belongs to the member who asked for it, in Settings or through the Router. The device it installs is theirs (`owner_user_id`), and they set its access in Settings > Devices.
Reuse uncertain commands. Verify `connection-check.txt` through the exact Device/Environment.
Runners use BFT device-code auth. Group Connectors use Salix credentials, without BFT login.
Reconnect updates routes and fences stale runs. Manager loss or upgrade cannot stop independent workloads. Reject unsupported operations locally.
Station cutover: [Station](architecture/DOMAIN_CONCEPTS.md#station).

## Comma desktop machine accounts

Desktop stations do not import local CLI logins automatically.
Settings > Devices shows installed Codex and Claude Code CLIs on this computer.
A usable login shows a switch. Unsigned and keychain-only logins show sign-in.

The switch controls its `machine-<runtime>` station profile. Only the computer owner can change it or sign in; without an owner, Workspace owners and admins can.
`POST /machine-logins` runs `claude auth login` or `codex login` on this station in the person's home.
The CLI opens its browser page and receives approval on its local callback. Credentials stay in a profile-readable file.
Success refreshes inventory and enables the machine profile. `machineSignIns` reports results and why a login was not used.

Profile removal blocks later turns, including warm sessions. Sent turns can finish.
Other profiles, credentials and history remain. Restart and refresh do not enable removed accounts.
Upgrades preserve enabled profiles. Cloud VM controls are separate.

The page reads this station on entry or focus. Each edit sends one request. After an uncertain reply it reads this station once; it never polls other devices.

## Compute and VMM

Project/Swarm/Group owns Compute Environments. Device access is separate.
Bound offline requests. Input awaits READY. Recovery repairs hints without Session polls.
Preserve bindings, accepted input, tool deadlines and receipts. Explicit targets and accepted work keep their selected machine.
See [deadlines](agent-runtime.md).
VMM gateway secrets remain independent of [Comma candidate-Secret rollout](release-operations.md).
VMM Host and user Device disk disposal needs owner approval; Cloudflare Group VMs follow the policy below.
Compute uses [billing facts](billing-models.md), not delayed usage telemetry.

Authorized Worker selection wakes archived Cloudflare Workloads with a 30s demand hold.
A ready Group VM archives after `idle_archive_ms` (5 minutes) with no Salix operation, no agent settle after one, and no Task Message its station posted or was given. A station that refuses to park waits the idle period again, doubled per refusal in a row, at most four times, until the VM is used again.
See [Tasks](../systems/station/docs/tasks.md) for station wake when Salix cannot give a Task Message to an unconnected Group VM station.

Shell Host tunnels keep their gRPC connection while idle, until session expiry, revocation, or transport loss; a Host request that finds the tunnel gone marks the current session stale and its ready Workload pending.
The bounded Compute reconciler replaces missing, stale, or expired shell sessions even when the Host connection epoch has not changed.
Discovery reports observed state without a Host probe and does not guarantee current execution availability.

Shell cleanup, seven-day authorization and remnants: [settings](product-features.md#compute-node-settings-and-initialization).

### Linux Compute Host installation

Get the Linux install command in Cue Settings > Devices or BFT Project Compute. Run it on Linux arm64 with sudo, systemd and KVM access. The server fixes the Group; no desktop app or separate login is needed.

The secret-free GET script POSTs the ticket argument in a body, never a URL. The reply runs the tar archive's `agent-vmm lifecycle install`.
Native owns systemd and recovery. Reuse uncertain commands. Downloads neither rotate nor consume the ticket.
Exchange fixes the Host and material deadline. A saved plan or completion receipt resumes. Without either, the same Host can recover material before that deadline.
Closed handoffs without either need attention in Compute settings.
BFT shows its existing Compute Host binding after a lost command. Revoke that authorization before you generate a new command.
Unknown results do not trigger automatic revocation.

## Automatic Station placement

Authorized Group Hosts prepare reusable VMM Stations alongside existing Cloudflare Stations.
Runtime Tasks without a chosen location prefer VMM, the requester's authorized physical Station, then enabled Cloudflare.
Creation receipts keep the selected target across retries.
Managed Stations use cloud-authorized profiles. Physical machine logins require the owner's opt-in.

## Cloud VM data policy

Cloudflare Group VM disks are disposable, including edits, dependencies, native history, and local auth.
Archive and restore are best effort; after bounded recovery fails, rebuild the exact VM. Local disk loss needs no further approval and must not block a release.
A Container's disk lives only as long as the Container. Salix never starts a ready VM's stopped Container empty: it seals the Gateway control and releases the Container, as an archive does, so the VM is `archived` with its last archive and wakes from it.
Salix never archives a stopped Container; with no archive the VM starts empty and its record keeps `container_loss`.
A wake's Container restores the archive before it starts its station; if it cannot, it exits and no station connects.
An archive is the Container's whole `/workspace` tree: the station data directory `/workspace/.comma/station` and the home `/workspace/.salix/sprite-home` (`/home/sprite` links to it).
It leaves out live database files (snapshots travel instead), `run/` runtime state (a restore drops it), runtime homes' `.tmp`, regenerable caches under the home (`.cache`, `.npm/_cacache`, `.codex/tmp`, package-manager stores), and links out of `/workspace`.
Each Task's Session starts with an empty workspace of its own under `/workspace/.comma/station/sessions/`, kept until that Session is deleted.
`HOME` is the archived `/home/sprite/.local/share/salix/connector-home` (`.codex`, `.claude` too); restored entries get new timestamps at wake.
`pip install --user` (`PYTHONUSERBASE=/home/sprite/.local`, outside `HOME`) and `npm install --global --prefix /home/sprite/.local` land under the archived `/workspace/.salix/sprite-home/.local` and survive.
`npm install --global` without `--prefix` lands in the image's `/usr/local` and is gone at the next wake.
Nothing outside `/workspace` survives a wake: it is the image.

Preserve Salix-owned Sessions, Messages, queues, credentials, and execution records.
Never replay unknown effects or restore old pending execution after reset. Fence commands and confirm the exact carrier stopped.
Keep usable archives and report interrupted work or required login. Use Workload owner operations, never direct database edits.
Finish the generation-aware Comma rollout before reset. Do not restore an older serving binary afterward.
A reset advances the Workload generation. Sessions keep input with an unknown outcome and never replay it.

## Coding sandboxes

A sandbox Task (`runs_on {kind: sandbox}`) runs on an L4ES VM of its own. With `repo {owner, name, base_ref?, branch?}` it is a coding Task: GitHub changes go there unless a named machine or local files are needed. Without `repo` it has no checkout, GitHub grant, git identity, save, diff or pull request.
Other places and retries reject `repo`. A Worker may be bound to a sandbox: each of its Tasks takes a live-sandbox slot, and where sandboxes are not set up they are refused. Models use runtime defaults. Salix selects resources and credentials.
Image contents: [L4ES sandboxes](../systems/DEPLOYMENT.md#l4es-sandboxes).

`SalixWeb.CodingSandboxes` owns creation, recovery, stopping and turn `facts`. `SalixStore.CodingSandboxes` stores them on the Workload.
Group Stations and Task sandboxes share execution and connection authorization. Disk/resource policies differ.

- Identity: the Task owns an Environment on the tenant's `l4es` Pool, a ProviderBinding, and a `coding_sandbox` Workload.
  Each run gets an Allocation and advances the Environment and Workload generation.
  Device `dev-sbx-<task>` is stable. Commands, credentials, account profiles and the platform model need the current authorized Workload connection; old-generation and terminal connections get none.
- Creation: placement checks a coding Task's repository through the Group's GitHub binding, and the live-sandbox limit: the Workspace's admin override or `SALIX_L4ES_MAX_SANDBOXES` (default 5).
  A `starting` Workload reserves the Task's sandbox. A worker creates it from `SALIX_L4ES_IMAGE` with its connect credential and, for a coding Task, a GitHub grant and the owner's git identity.
  Its Station connects, accepts the Task, and checks out a coding Task's branch before the first turn.
- Calls: L4ES takes a 300-second assertion from `CommaWeb.Coding.L4ESAssertions`. Before a create or terminal, Salix makes non-viewers L4ES members, who sign in with Comma.
- Checks: each node takes at most 20 Workloads per 15 seconds, with a 2-minute lease. Ready ones are checked each 5 minutes.
  A Task is in review once its Session ends a turn with no follow-up, active on one. A coding Task's work is pushed; the sandbox stops after 3 idle minutes in review or ended, else 2 hours.
  After 24 idle hours, it stops and a coding Task records any lost work.
  No connection in 5 minutes makes the sandbox `failed`. A sandbox L4ES no longer runs is `lost`.
- Recovery: a Message resumes a `stopped`, `lost`, `failed`, or `ended` sandbox. L4ES starts it from its kept disk.
  A refused start (409) remakes it on a new disk, unless it is still stopping.
  Replacement waits until L4ES says the old run stopped. An unknown invite or stop result never authorizes a second carrier.
  A Station on a new disk gets the Task start and goes on from the pushed branch.
- Completion: completed, cancelled, failed, and archived Tasks end their sandbox. Failed stops retry each minute by name.
- GitHub (coding Tasks): L4ES holds and Salix renews the token. Initial grants allow repo-wide reads and Task-branch writes. See [Router ACL updates](architecture/DOMAIN_CONCEPTS.md#coding-sandboxes).
- Accounts: a selected `account_id` limits subscription profiles to that account, also when lookup fails.
- Billing: VM time runs from `ready` to stop, with provider `l4es` and SKU `sandbox-<size>`. Only a priced SKU charges.

Sandbox disks are unarchived and L4ES can evict stopped ones; Task Messages and pushed branches are durable.
Session state, changes, history, token use, PRs and terminals use `/v1/comma/workspaces/:id/coding`.
Deployment: [L4ES sandboxes](../systems/DEPLOYMENT.md#l4es-sandboxes).

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

Host/ProviderBinding epochs fence routes. RuntimeInstance epochs fence execution.
Creation fences allocation generation/execution/container instance. Dispatch checks route/state/generations/credentials/epochs.
Reconnect keeps generation. Resume needs fresh inventory and keeps consumed bootstrap/in-flight identity. Ready/retained reports keep draining. Release/revoke retires authority.
Late bootstrap cannot change epochs. Pending input alone can change execution epoch. In-flight input blocks replacement.

Bootstrap expiry repairs only never-authenticated execution. Otherwise use runtime credentials.
Repair requires quiesce and exact-instance stop. Stop/delete request IDs include instance/container generation.
Fresh stopped inventory commits Allocation facts and ready→pending Workload together. Volumes remain.
New Start identity uses container generation and last successful Start instance. Retries keep it.
Unknown outcomes preserve target and accepted input. Meeting bootstrap/in-flight rules apply.

Host Session commit wakes its Workload without stealing claims. Container proof permits credential reuse.
Sweeps repair missed wakes. Readiness clears the deadline. Manual retry preserves age. Gateway errors omit private metadata and use finite reasons.
The owner recovers exited loops. Preserve children, credentials, volumes, and accepted work. Verify a task response.

Migration preserves credentials/container identity/volumes/accepted work. Missing/contradictory inventory fails closed within budget.
A Host hello drops unknown or contradictory inventory entries instead of failing. Epoch and generation fences stay.

## Mac apps on a member's Mac

The `mac-apps` plugin binds MCP `mac` to one member's Mac: `placement: device`, the device's Connector runtime, and `owner_user_id`. Only the Comma desktop app on a Mac lists it, and installs it with its device ID. The member turns apps on inside it; every app starts off. See [Mac apps plugin](architecture/DOMAIN_CONCEPTS.md#mac-apps-plugin).
Salix sends each JSON-RPC message with the Connector method `client_mcp` (`server: "mac-apps"`). The station forwards it to Main with Main's bearer. A device with Read access accepts it; Off refuses it like a read. No device port, URL or token reaches Salix.
Main serves only the apps the user turned on. The switches stay on that Mac as the only switch authority, shared by every workspace connected there. A change installs the plugin again, which rediscovers the tools. Uninstall removes the workspace's binding and leaves the switches.
MacAppsHost runs the tools as Comma's child, so macOS attributes permissions to Comma. A call without a permission returns `permission_required` and never prompts. Only the user's switch in Comma requests a permission: turning Vision on also takes one screen capture, so macOS asks then whether Comma may capture without its window picker. An app opened only for its Automation prompt is closed again. Comma does not read Messages history: that needs Full Disk Access, which every command its station runs would share. A switch macOS did not allow stays off, and Plugins says so. macOS reads Screen Recording into a process when it starts. After the user goes to System Settings for it, Main starts a new MacAppsHost when it reads the state, while no call runs, for up to 10 minutes or until the grant shows. The user does not restart Comma.
A `client:` binding runs only when the turn's requester owns the device it reaches, as the device registry records; no binding field decides. A Worker's turn in an ordinary one-shot Task counts as the person whose own Router message created the Task, for the Task's first command only. A later command the Router sends into the Task, background work, schedule fires, Loop wakes, scheduled and Loop Tasks, and other members get an error. An Agent's `mcp_manager` cannot create or change such a binding. Only Comma's own MCP definition may use the `comma-client` transport: Salix refuses it in any other definition. Results keep the Group connector label.
An offline Mac returns `device_offline`. Calls are not queued or replayed. A write that times out has an unknown outcome, and the error says so. MacAppsHost does not start an AppleScript call whose deadline passed while it waited for the main thread. The station aborts a request Main has not answered in 30 seconds. A change to a recurring event must name its occurrence (`occurrence_start`).
A result that made or found Calendar events, reminders, notes, contacts or places also gives the Agent up to five `mac_app_item` cards for its reply. Comma on a Mac draws each as its app does and opens the item there; other clients show text.
