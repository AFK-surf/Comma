# Comma station

The station is the resident process on every machine that serves Comma: user devices, Cloud VMs and Compute
workloads. It replaces the Go `salix-connect` connector. Conversations with external runtimes (Codex, Claude) are
station-local chats, as in Comma. The station keeps each chat, its messages, its state and the native session.
Salix hands a Worker's input to a chat and reads the chat's outcome.

- The code is Comma's station (`AFK-surf/still.fail` `station/`, imported from `9c5146d9`), extended with what
  only the Go connector did. The two copies evolve separately.
- Logic is Effect TypeScript (`effect` 4). Native parts are Rust, prebuilt and content-addressed
  (`scripts/native.ts`). Daily work never compiles Rust.
- Not ported from the connector: the Android emulator, `--vm-server`, Windows paths, the Kimi and Pi runtimes,
  retired flags and `--stdio`.
- Salix's server-owned external sessions (the `agent_runtime_input` inbox and ACKs, the runtime event outbox, Host
  execution rights for main executions, session migration) are deleted. Existing sessions move into station chats
  once, at the cutover.

## Layout

| Path | Contents |
| --- | --- |
| `src/` | The station (`docs/station-ts.md` for its structure) |
| `native/` | The launcher, the per-agent runner and the iroh addon (Rust) |
| `vendor/` | Patched iroh crates (`vendor/README.md`) |
| `i18n/` | The station's message catalogs |
| `docs/` | Comma's station design documents |
| `scripts/native.ts` | Finds, downloads or builds the native parts |

## Commands

```sh
pnpm --dir systems/station check
pnpm --dir systems/station test
node systems/station/scripts/native.ts status
```

## How Salix reaches the station

Every station connects out to Salix the same way, whatever machine it runs on.

- **Two kinds of connection.** With Salix (and Comma's control plane, on the same server), a station speaks
  WebSocket or HTTPS. With other stations and with client apps, it speaks iroh.
- **Salix as a relay.** Salix forwards iroh packets between the stations and clients of a Workspace
  (an iroh custom transport). A station sends them over its connector socket. A client app opens Comma's client relay
  socket for each Workspace with a single-use ticket. No separate relay service is deployed.
- **A desktop's own station.** It is in no roster. When the app's Debug setting says so, each device connection asks
  Salix for its Group's facts with the proof of the key, and the station serves only `comma/mesh/1`, only to that
  device's owner, and announces nothing (`src/mesh/device-mesh.ts`, [Station](../../docs/architecture/DOMAIN_CONCEPTS.md#station)).
- **Pacing.** The mesh addon's QUIC connections use BBR, so a bulk transfer keeps the queue at a slow link short and
  other requests on that link are not held behind it.
- **One connection to Salix.** The station dials Salix's `/v1/connect` and speaks the connector protocol
  (`src/connector/`, run by `src/connector/service.ts`). This holds on a user's computer, in a Cloud VM (Cloudflare
  Sandbox) and in an Agent VMM container. The station listens on no port for Salix. Stream chunks (file reads and
  writes, LAN tunnels) go as binary frames, a JSON head and then the raw bytes, never as base64
  (`SalixEnv.Protocol.encode_stream_binary`); each side keeps base64 JSON for a peer that does not say it takes them.
- **Two kinds of credential.**
  - A device credential: the connector token of a user's computer. Electron Main mints it with the user's Session,
    for 2 hours. A device connection is served only while it holds an unexpired, unrevoked credential for its device,
    and Salix closes the socket when the credential it holds expires. The connection starts with the credential that
    admitted it. A quarter of its life before that credential expires, the app mints the next one and writes it to
    the instance file. The station presents it on the live connection (`connector_credential_renew`, which Salix
    offers in `connected`). The connection, its requests and its processes stay, and the new credential now bounds
    the connection. A computer without the app (`/stations/install.sh`) gets its credential from its enrollment: it
    has no expiry and ends when the device is removed. Salix never mints a device credential for a connection by itself. A newer credential does not
    end the live connection of an older one before the older one expires, but the older one admits no new
    connection. When Salix refuses the new credential, or does not offer renewal, the station connects again with it.
  - A workload credential: the connect credential the Compute provider gives the container when it starts it
    (`SALIX_WORKLOAD_CREDENTIAL`, from `Compute.WorkloadCredential.issue_connect`). It names the Workload and its
    generation and has no expiry. The station presents it on every connection, also after it restarts. It works while
    the Workload stays at that generation. A Cloud VM reset or the next run of a coding sandbox advances the
    generation. Salix refuses a connection whose generation is not current. It checks the generation again before each
    command, except reads and commands that stop work. The station takes it out of its environment when it starts:
    its `exec` commands, jobs and agent runtimes do not inherit it. They run as the station's user, which is root in
    a Cloudflare Container. So they can still read it from the start environment of the station's parent processes
    (`/proc/<pid>/environ`). In a coding sandbox they can also read `/run/sbx/secrets`. What the station runs can
    therefore act as the station.
- **What a credential allows.** Both allow environment work and Salix's Tasks. Only a workload credential may
  quiesce, release and resume its runtime, and export or import its archive. An archive moves over the connection:
  the station uploads to, or downloads from, the pre-signed URLs Salix gives it. A workload credential also places
  a Group Workload's station in the workspace's station roster when it connects. Salix takes the key that the
  connection reports (`station_identity`) and asks for no proof of it. So a holder of the credential can place there
  any key that is not in another Group's roster. A coding sandbox's station is not placed.
- **Salix's Tasks.** Salix is the Station a Task is kept on. A Worker running here is a Session of this station
  taking part in it (`docs/tasks.md`). Salix sends `task.invite` to begin the Session and `task.put` with the Messages
  it has not had. The station writes into the Task with `task.post` and says `task.hello` when it connects, over the
  same connection.
- **People reach a user's station directly.** A Comma client core connects over iroh with `comma/mesh/1`
  (`@comma/mesh`, `src/mesh/comma.ts`), with the member credential the Comma protocol takes.
- **The desktop app runs one station per machine.** It carries the release (`scripts/bundle.sh`, with its own Node,
  because the app's RunAsNode fuse is off). It runs the station with its data in the app's own directory. Each
  signed-in Workspace's connection is a connector instance inside it: a file in `<data>/connector/instances` that the
  app writes with a short-lived credential and removes at sign-out. A static connector the user installs is one more
  instance. launchd then runs the station, so it stays when the app quits.
- **macOS folder permissions.** The app's station is the app's child, so macOS attributes its file access, and that
  of the commands and agents it starts, to the app. The first open of Desktop, Documents or Downloads shows the app's
  prompt with its usage string, on that Mac. The open waits until someone answers. macOS never asks for a station
  that launchd runs.
  - The station cannot see whether a prompt shows, and an EPERM does not prove privacy protection (an immutable file
    also gives EPERM). The errors say only what is known and give possible causes.
  - A file read (`read`, `list`, `stat`, `glob`, `grep`) in one of these folders that has not finished in 5 seconds
    gets an error that says so. For the app's station, it asks the user to look for a prompt on that computer and to
    allow it if it shows. If no prompt shows, slow I/O is another possible cause, and the agent offers to wait or try again. For a
    launchd station, the error gives slow I/O as the cause and Full Disk Access only as a possible cause. The read
    goes on, so an answer to a prompt is kept.
  - An EPERM from opening, listing, creating, renaming or removing a file in one of these folders keeps the original
    error and adds privacy protection as a possible cause, with where the user can allow access: Files and Folders
    for the app, or Full Disk Access for a launchd station. Other errors are unchanged.
  - A search (`glob`, `grep`) that starts at the home directory or above opens these folders first, one at a time.
    All of them share one 5-second deadline, so the search waits at most 5 seconds more. If a folder has not opened
    by then, the search gets the same error as a slow read. A search that only takes long is not cut short. A request
    that the station refuses opens no folder.
  - A shell command (`exec`) whose stderr has a line that says `Operation not permitted` about a path in one of these
    folders keeps its output, and gets the same guidance added to its stderr. A line on stdout (for example from
    `2>&1`) counts only when the command fails. A non-zero exit by itself does not count. The line does not prove
    privacy protection (an immutable file gives the same words, and a command can print them), so the guidance gives
    it only as a possible cause.
  - These hints end with the `comma:screen/<device id>/display` link, so the user can look from another device. A
    launchd station's slow read has no link. The station picks the app's hints when the app's `COMMA_APP_PID` is in its environment. This is a
    heuristic, not proof of who started the station.
  - Off macOS, errors are unchanged.

This removes the runtime agent's listener (`/connect`, `/archive`, `/control` on the container), Salix's reverse
dial into Cloud VMs and the gateway's forwarding to the container, and the Compute runtime carrier
(`ComputeRuntimeSocket`, `ComputeRuntimeCarrier`).

Cloudflare Group VMs retire through the [Cloud VM cutover](../../docs/agent-runtime.md#cloud-vm-cutover).
There is no Gateway image job or drain gate. Existing Workload owners stop them in the background.
Agent VMM Workloads change with the automatic Workload update after the release publishes the runtime catalog.
Their volumes stay. Desktop apps change with their update.

## Standalone release

`/stations/install.sh` installs this station on a computer without the desktop app. `station-release.yml` publishes
main's release to `https://cue-release.afk.surf/station-release`: `<commit>/comma-station-<platform>.tar.gz`,
`latest.json`, and `inputs/<hash>.json` (`scripts/release-inputs.sh`). A Comma release pins the manifest of its
revision's input hash.

## Cutover plan

1. Station side.
   Done: environment work (files and streams, exec and processes, HTTP and LAN, `read_ref`, Computer Use, meetings,
   device access), Workers as chats, the workload credential, quiesce/release/resume, durable archive export and
   import over the connection with database snapshots, no listener.
   Open: runtime auth and subscription access, dependency installations.
2. Salix side.
   Done: device Workers as Task Sessions (`SalixWeb.StationTasks`), the workload credential on `/v1/connect`
   (`Compute.WorkloadCredential`, with the generation fence), Cloud VM and Agent VMM providers issue it to
   the containers they start.
   Done too: the Compute runtime carrier is deleted; a Group's meetings on its Agent VMM Host run on its VMM
   Station, which runs meet-native beside the station.
   Open: archives through `archive_*`, Workload Workers as chats. The Cloud VM reverse dial goes (the old export
   stays for the switching release).
3. Salix's external session runtime path is deleted. The External Session keeps the Conversation source frontier
   only.
4. The Electron app, install scripts and runtime images start the station. `systems/connector/salix-connect` is
   deleted.
