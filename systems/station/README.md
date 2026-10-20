# Comma station

The station is the resident process on every machine that serves Comma: user devices, Cloud VMs and Compute
workloads. It replaces the Go `salix-connect` connector. Conversations with external runtimes (Codex, Claude) are
station-local chats, as in still.fail. The station keeps each chat, its messages, its state and the native session.
Salix hands a Worker's input to a chat and reads the chat's outcome.

- The code is still.fail's station (`AFK-surf/still.fail` `station/`, imported from `9c5146d9`), extended with what
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
| `docs/` | still.fail's station design documents |
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
- **Salix as the relay of last resort.** Salix forwards iroh packets between the stations and clients of a Workspace
  (an iroh custom transport). A station sends them over its connector socket. A client app opens Comma's client relay
  socket for each Workspace with a single-use ticket. No separate relay service is deployed.
- **Pacing.** The mesh addon's QUIC connections use BBR, so a bulk transfer keeps the queue at a slow link short and
  other requests on that link are not held behind it.
- **One connection to Salix.** The station dials Salix's `/v1/connect` and speaks the connector protocol
  (`src/connector/`, run by `src/connector/service.ts`). This holds on a user's computer, in a Cloud VM (Cloudflare
  Sandbox) and in an Agent VMM container. The station listens on no port for Salix.
- **Two kinds of credential.**
  - A device credential: the connector token of a user's computer.
  - A workload credential: given by the Compute provider when it starts the container. It names the Workload, the
    runtime instance, the generation and the connection epoch. It starts as a one-time bootstrap credential that the
    first handshake exchanges for a short-lived one. The station keeps that one in memory only and renews it over the
    connection. Salix refuses a connection, and every command, whose generation or epoch is not current.
- **What a credential allows.** Both allow environment work and Salix's Tasks. Only a workload credential may
  quiesce, release and resume its runtime, and export or import its archive. An archive moves over the connection:
  the station uploads to, or downloads from, the pre-signed URLs Salix gives it.
- **Salix's Tasks.** Salix is the Station a Task is kept on. A Worker running here is a Session of this station
  taking part in it (`docs/tasks.md`). Salix sends `task.invite` to begin the Session and `task.put` with the Messages
  it has not had. The station writes into the Task with `task.post` and says `task.hello` when it connects, over the
  same connection.
- **People reach a user's station directly.** A Comma client core connects over iroh with `comma/mesh/1`
  (`@comma/mesh`, `src/mesh/comma.ts`), with the member credential the still.fail protocol takes.
- **The desktop app runs one station per machine.** It carries the release (`scripts/bundle.sh`, with its own Node,
  because the app's RunAsNode fuse is off). It runs the station with its data in the app's own directory. Each
  signed-in Workspace's connection is a connector instance inside it: a file in `<data>/connector/instances` that the
  app writes with a short-lived credential and removes at sign-out. A static connector the user installs is one more
  instance. launchd then runs the station, so it stays when the app quits.

This removes the runtime agent's listener (`/connect`, `/archive`, `/control` on the container), Salix's reverse
dial into Cloud VMs and the gateway's forwarding to the container, and the Compute runtime carrier
(`ComputeRuntimeSocket`, `ComputeRuntimeCarrier`).

Switching: Cloud VMs change with the Gateway image job (the gateway and the image together, `sandbox_image`). For
that one release Salix keeps the old archive export through the old gateway, so the job can archive the running
containers before the new image replaces them. The next release deletes it. Agent VMM Workloads change with the
automatic Workload update after the release publishes the runtime catalog. Their volumes stay. Desktop apps change
with their update.

## Cutover plan

1. Station side.
   Done: environment work (files and streams, exec and processes, HTTP and LAN, `read_ref`, Computer Use, meetings,
   device access), Workers as chats, the workload credential, quiesce/release/resume, durable archive export and
   import over the connection with database snapshots, no listener.
   Open: runtime auth and subscription access, dependency installations.
2. Salix side.
   Done: device Workers as Task Sessions (`SalixWeb.StationTasks`), the workload credential on `/v1/connect`
   (`Compute.WorkloadCredential`, with the generation and epoch fence), Cloud VM and Agent VMM providers issue it to
   the containers they start.
   Open: archives through `archive_*`, Workload Workers as chats. The carrier and the
   Cloud VM reverse dial go (the old export stays for the switching release).
3. Salix's external session runtime path is deleted. The External Session keeps the Conversation source frontier
   only.
4. The Electron app, install scripts and runtime images start the station. `systems/connector/salix-connect` is
   deleted.
