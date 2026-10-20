// The station on the mesh, once it is in a workspace (cloud.json there): its endpoint, its relays, its presence at
// its control plane, members' connections, and the control plane's gateways' (the device tools, mesh/tools.ts). Everything here lives in the layer's scope: stopping the station closes
// the endpoint and every connection and loop it started.
import { Cause, Effect, FiberSet, Layer, Option, Stream } from "effect";
import { log } from "../ops/log.ts";
import { AdbShares, AdminApi, ControlPlane, Key, MeshNative, Store, Up } from "../services.ts";
import { DeviceTools, accessOf } from "../device/tools.ts";
import { claudeCredentialsFile, codexAuthFile } from "../agents/machine-logins.ts";
import { TOOLS_ALPN, adminSessions, presenceTools, serveTools } from "./tools.ts";
import { Agents } from "../sessions/agents.ts";
import { PEER_ALPN, followRoster, peerCall, servePeer } from "./peer.ts";
import { Traces } from "./traces.ts";
import { SubscriptionRef } from "effect";
import { keepRelays } from "./relays.ts";
import { ALPN, FORMER_ALPN, serve } from "./serve.ts";
import { COMMA_ALPN, serveComma } from "./comma.ts";
import { SalixRelay } from "./salix-relay.ts";
import { meshPort } from "./native.ts";
import { followReach } from "./reach.ts";

export const MeshLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const plane = yield* ControlPlane;
    const cloud = plane;
    const store = yield* Store;
    const key = yield* Key;
    const native = yield* MeshNative;
    const relay = yield* SalixRelay;
    const admin = yield* AdminApi;
    const up = yield* Up;
    const agents = yield* Agents;
    const shares = yield* AdbShares;
    const run = Effect.gen(function* () {
      // Not in a workspace yet: on the mesh once `enroll` writes cloud.json.
      if (!cloud.state.state) yield* cloud.changes.pipe(Stream.filter(() => cloud.state.state !== null), Stream.runHead);
      const port = meshPort(agents.config.raw());
      // The launcher starts this process before it stops the old one, and a fixed UDP port is not shared: wait here, in
      // the background, for the old one to be gone (not in the layer's construction, which must let the station say it
      // is ready for the handover to go on). Any free port binds beside the old process's.
      if (port !== undefined) yield* Effect.promise(() => agents.previousGone);
      const endpoint = yield* Effect.acquireRelease(
        Effect.promise(() => native.bind({ secretKey: key.seed, alpns: [ALPN, FORMER_ALPN, PEER_ALPN, TOOLS_ALPN, COMMA_ALPN], relayUrls: cloud.state.relays(), discovery: process.env.STILLFAIL_NO_DISCOVERY !== "1", bindAddr: port === undefined ? undefined : `0.0.0.0:${port}`, salixRelay: true })),
        // iroh closes gracefully, waiting on every connection (the keepers' too): up to ~12 s. A station stopping or
        // handing over doesn't wait that long: a second, then it is gone (clients reconnect, as they do anyway).
        (endpoint) => Effect.ignore(Effect.timeoutOption(Effect.promise(() => endpoint.close()), "1 second")),
      );
      log.info("mesh", "mesh listening", { station: endpoint.id(), workspace: cloud.state.state!.workspace_name, sockets: endpoint.sockets() });
      yield* Effect.forkScoped(keepRelays(endpoint));
      yield* Effect.forkScoped(followReach(endpoint, cloud.state));
      // Packets for Salix, the relay of last resort, go out on the connector's connection to it (salix-relay.ts).
      yield* Effect.forkScoped(Effect.promise(() => relay.pump(endpoint)));
      // Online at the cloud only once a relay can reach the station: a device that saw "online" and connected before
      // the relay link was up had its first packets dropped (~3 s of retransmits).
      const online = yield* Effect.timeoutOption(Effect.promise(() => endpoint.online()), "15 seconds");
      if (Option.isNone(online)) log.warn("mesh", `no relay link after 15 s; going online at ${plane.spec().name} anyway`);
      yield* Effect.forkScoped(plane.presence);
      // The workspace's other stations: asked through this endpoint, their tasks stopped once they are not in it.
      agents.remote.attach(peerCall(endpoint, cloud.state));
      yield* Effect.acquireRelease(
        Effect.sync(() => followRoster(cloud.state, agents.remote, agents.config)),
        (stop) => Effect.sync(stop),
      );
      // Each roster the control plane gives (at every presence connection): Tasks across stations go on (tasks.ts).
      yield* Effect.acquireRelease(
        Effect.sync(() => cloud.state.listen(() => cloud.state.peersCurrent && agents.tasks.connected())),
        (stop) => Effect.sync(stop),
      );
      const connections = yield* FiberSet.make();
      // The mesh's spans, when the config turns traces on (read at start, as the Rust does).
      const traces = yield* Effect.acquireRelease(
        Effect.sync(() => new Traces(agents.config.raw()?.telemetry?.traces === true)),
        (traces) => Effect.promise(() => traces.close()),
      );
      if (traces.enabled) traces.exportTo((spans) => Effect.runPromise(plane.traces(spans)));
      const members = { cloud: cloud.state, admin, up: () => SubscriptionRef.getUnsafe(up), shares, traces, accepted: plane.credential };
      // The control plane's gateways: the device tools, as far as the station's own setting lets them.
      const device = yield* Effect.acquireRelease(
        Effect.sync(() =>
          new DeviceTools({
            // Never reachable: the station's data (its key, cloud.json, the profiles' homes), its config, the machine's
            // runtime logins.
            protect: () => [
              cloud.state.data,
              agents.config.path,
              ...agents.hub.config().profiles.map((p) => p.home),
              claudeCredentialsFile(process.env),
              codexAuthFile(process.env),
            ],
            sessions: adminSessions(
              () => admin,
              () => store,
              () => agents.hub.config().profiles.flatMap((p) => p.runtimes),
              () => cloud.state.state?.workspace ?? "",
              endpoint.id(),
            ),
          }),
        ),
        (tools) => Effect.sync(() => tools.close()),
      );
      const gateways = { cloud: cloud.state, tools: device, access: () => accessOf(agents.config.raw()), enabled: () => plane.spec().tools };
      // The same tools for requests Comma pushes on the presence socket.
      cloud.state.toolCalls = presenceTools(gateways);
      yield* Effect.addFinalizer(() => Effect.sync(() => (cloud.state.toolCalls = null)));
      for (;;) {
        const conn = yield* Effect.promise(() => endpoint.accept());
        if (!conn) return;
        yield* FiberSet.run(
          connections,
          Effect.tryPromise(() =>
            conn.alpn().equals(PEER_ALPN) ? servePeer(conn, cloud.state, agents.remote)
            : conn.alpn().equals(TOOLS_ALPN) ? serveTools(gateways, conn)
            : conn.alpn().equals(COMMA_ALPN) ? serveComma(members, conn)
            : serve(members, conn),
          ).pipe(
            Effect.catch((e) => Effect.sync(() => log.info("mesh", "connection ended", { error: String((e as Error).cause ?? e) }))),
            Effect.ensuring(Effect.sync(() => conn.close(0, "station stopping"))),
          ),
        );
      }
    });
    // A named port taken by something else (or a mesh.port that does not check out) leaves the station off the mesh:
    // said in the log, never another port.
    yield* Effect.forkScoped(
      Effect.scoped(run).pipe(
        Effect.tapCause((cause) =>
          Effect.sync(() => {
            if (!Cause.hasInterruptsOnly(cause)) log.error("mesh", "mesh stopped", { error: Cause.pretty(cause) });
          }),
        ),
      ),
    );
  }),
);
