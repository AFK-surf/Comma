// The station on the mesh, once it is in a workspace (cloud.json there): its endpoint, its relays, its presence at
// its control plane, members' connections, and the control plane's gateways' (the device tools, mesh/tools.ts). Everything here lives in the layer's scope: stopping the station closes
// the endpoint and every connection and loop it started. A desktop's station, which is in no workspace by cloud.json,
// is on the mesh for its owner alone while a device connection's Salix says so (device-mesh.ts): only `comma/mesh/1`,
// with nothing of the roster's (no peers, no gateways, no presence).
import { Cause, Effect, FiberSet, Layer, Option, Stream } from "effect";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { AdbShares, AdminApi, ControlPlane, Key, MeshNative, Paths, Store, Up } from "../services.ts";
import { DeviceTools, accessOf } from "../device/tools.ts";
import { claudeCredentialsFile, codexAuthFile } from "../agents/machine-logins.ts";
import { Superseded } from "./gone.ts";
import { TOOLS_ALPN, adminSessions, presenceTools, serveTools } from "./tools.ts";
import { Agents } from "../sessions/agents.ts";
import { FORMER_PEER_ALPN, PEER_ALPN, followRoster, peerCall, servePeer } from "./peer.ts";
import { Traces } from "./traces.ts";
import { SubscriptionRef } from "effect";
import { keepRelays } from "./relays.ts";
import { ALPN, FORMER_ALPN, RENAMED_ALPN, serve } from "./serve.ts";
import { COMMA_ALPN, serveComma, serveDeviceComma } from "./comma.ts";
import { makeScreenViews } from "./screens.ts";
import { ScreenHelpersService, helperSources } from "../screens/helper.ts";
import { AndroidDevicesService } from "../screens/devices.ts";
import { avdsOn, emulatorPath, startEmulator } from "../screens/emulator.ts";
import { SimulatorsService } from "../screens/simulator-agent.ts";
import { WindowsDesktop, windowsScreenBinary } from "../screens/win-desktop.ts";
import { LinuxDesktop, hasLinuxDesktop } from "../screens/linux-desktop.ts";
import { adbPath } from "./adb.ts";
import { SalixRelay } from "./salix-relay.ts";
import { meshPort } from "./native.ts";
import { followReach } from "./reach.ts";
import type { DeviceMeshAdmissions } from "./device-mesh.ts";

/// Waits for what `admissions` says to meet `wanted`.
/// How long the endpoint outlives the last admission, for what was said to go.
const LAST_WORD_MS = 500;

/// How long an emulator being started is taken to be on its way: past this, starting it again is a person's to try.
const STARTING_MS = 3 * 60_000;

const whenAdmissions = (admissions: DeviceMeshAdmissions, wanted: boolean) =>
  Effect.callback<void>((resume) => {
    if (admissions.active() === wanted) return resume(Effect.void);
    const stop = admissions.listen(() => {
      if (admissions.active() !== wanted) return;
      stop();
      resume(Effect.void);
    });
    return Effect.sync(stop);
  });

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
    const helpers = yield* ScreenHelpersService;
    const android = yield* AndroidDevicesService;
    const { data } = yield* Paths;
    const admissions = relay.admissions;
    // The endpoint of a desktop's station, while its Salix says whom it admits (device-mesh.ts).
    const deviceEndpoint = Effect.gen(function* () {
      const port = meshPort(agents.config.raw());
      if (port !== undefined) yield* Effect.promise(() => agents.previousGone);
      const endpoint = yield* Effect.acquireRelease(
        Effect.promise(() => native.bind({ secretKey: key.seed, alpns: [COMMA_ALPN], relayUrls: admissions.relays(), discovery: false, bindAddr: port === undefined ? undefined : `0.0.0.0:${port}`, salixRelay: true, routePolicy: admissions.routePolicy() })),
        (endpoint) => Effect.ignore(Effect.timeoutOption(Effect.promise(() => endpoint.close()), "1 second")),
      );
      log.info("mesh", "this computer on the mesh, for its owner", { station: endpoint.id(), sockets: endpoint.sockets() });
      endpoint.keep(admissions.relays());
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          let ours = admissions.relays();
          return admissions.listen(() => {
            const now = admissions.relays();
            if (JSON.stringify(now) === JSON.stringify(ours)) return;
            const was = ours;
            ours = now;
            void Promise.all([...now.filter((u) => !was.includes(u)).map((u) => endpoint.insertRelay(u)), ...was.filter((u) => !now.includes(u)).map((u) => endpoint.removeRelay(u))]).then(() => endpoint.keep(now));
          });
        }),
        (stop) => Effect.sync(stop),
      );
      yield* Effect.forkScoped(Effect.promise(() => relay.pump(endpoint)));
      const connections = yield* FiberSet.make();
      const isUp = () => SubscriptionRef.getUnsafe(up);
      const sources = helperSources(() => helpers.current());
      // Windows' main display, through comma-desktop-screen (screens/win-desktop.ts): its views end with the endpoint.
      const windowsDesktop = yield* Effect.acquireRelease(
        Effect.sync(() => {
          const binary = windowsScreenBinary();
          return binary === null ? null : new WindowsDesktop({ binary });
        }),
        (desktop) => Effect.promise(() => desktop?.close() ?? Promise.resolve()),
      );
      // A Linux computer's desktop, the station user's X11 session (screens/linux-desktop.ts): likewise.
      const linuxDesktop = yield* Effect.acquireRelease(
        Effect.sync(() => (hasLinuxDesktop() ? new LinuxDesktop({ data }) : null)),
        (desktop) => Effect.promise(() => desktop?.close() ?? Promise.resolve()),
      );
      // Emulators on an adb server of the station's own, and the phones its owner chose, once a listing asks for them
      // (screens/devices.ts: the station's one set, which the agents' leases use too).
      const devices = android.screens;
      const androids = android.androids;
      // A Mac's iOS Simulators, through its Computer Use helper, once a listing asks for them: a list of their own, apart
      // from the Android devices (screens/simulator-agent.ts: the station's one set, which the agents' leases use too).
      const { screens: simulatorScreens, simulators } = yield* SimulatorsService;
      // Those started, not yet listed: a second start of one would only fail on its lock.
      const starting = new Set<string>();
      // Who may is the owner's connection's already (serveDeviceComma); a view also goes by the computer's access.
      const screens = makeScreenViews({
        sources: () => [...(helpers.current() ? sources : []), ...(windowsDesktop ? [windowsDesktop] : []), ...(linuxDesktop ? [linuxDesktop] : []), ...devices.list(), ...simulatorScreens.list()],
        devices: {
          refresh: () => androids.refresh(),
          phones: android,
          unavailable: () => androids.unavailable(),
          startable: async () => {
            const running = new Set(devices.list().map((source) => source.name));
            return (await avdsOn(emulatorPath(adbPath()))).filter((avd) => !running.has(avd) && !starting.has(avd));
          },
          start: async (avd, allowed) => {
            const emulator = emulatorPath(adbPath());
            // (taken at once: two asks for the one AVD start it once)
            if (emulator === null || starting.has(avd)) return null;
            starting.add(avd);
            const forget = () => void starting.delete(avd);
            if (!(await avdsOn(emulator)).includes(avd) || devices.list().some((source) => source.name === avd)) {
              forget();
              return null;
            }
            // (it comes on the station's adb server only while that is followed)
            await androids.refresh();
            const id = await startEmulator({ emulator, avd, env: androids.env(), ended: forget, allowed });
            if (id === null) forget();
            // Listed by then, or it will not be: `startable` looks at what is running.
            else wall.after(STARTING_MS, forget);
            return id;
          },
        },
        simulators,
        access: () => accessOf(agents.config.raw()),
        up: isUp,
        mayView: (member) => admissions.mayView(member),
        mayControl: (member) => admissions.mayControl(member),
        listen: (changed) => {
          const unadmit = admissions.listen(changed);
          const unconfig = agents.config.listen(changed);
          return () => (unadmit(), unconfig());
        },
      });
      // The station's agents link to these screens while it serves them (connector `screen_links`, screens/links.ts).
      yield* Effect.acquireRelease(
        Effect.sync(() => helpers.offerCatalog(() => screens.catalog())),
        (withdraw) => Effect.sync(withdraw),
      );
      // A device that connects again: the connections its killed process left are closed (gone.ts).
      const superseded = new Superseded();
      for (;;) {
        const conn = yield* Effect.promise(() => endpoint.accept());
        if (!conn) return;
        void superseded.arrived(conn);
        yield* FiberSet.run(
          connections,
          Effect.tryPromise(() => serveDeviceComma({ admin, up: isUp, screens }, admissions, conn)).pipe(
            Effect.catch((e) => Effect.sync(() => log.info("mesh", "connection ended", { error: String((e as Error).cause ?? e) }))),
            Effect.ensuring(Effect.sync(() => conn.close(0, "station stopping"))),
          ),
        );
      }
    });
    const onDeviceMesh = Effect.forever(
      whenAdmissions(admissions, true).pipe(
        Effect.andThen(
          Effect.scoped(
            Effect.raceFirst(
              deviceEndpoint,
              // Open views were told why they end, which has yet to go: over Salix nothing else will, as closing the
              // endpoint shuts its relay first, and a client told nothing waits out the connection's idle timeout.
              whenAdmissions(admissions, false).pipe(Effect.andThen(Effect.promise(() => wall.sleep(LAST_WORD_MS)))),
            ),
          ),
        ),
      ),
    );
    const run = Effect.gen(function* () {
      // Not in a workspace yet: on the mesh once `enroll` writes cloud.json; meanwhile for a device's owner.
      if (!cloud.state.state) yield* Effect.raceFirst(cloud.changes.pipe(Stream.filter(() => cloud.state.state !== null), Stream.runHead), onDeviceMesh);
      const port = meshPort(agents.config.raw());
      // The launcher starts this process before it stops the old one, and a fixed UDP port is not shared: wait here, in
      // the background, for the old one to be gone (not in the layer's construction, which must let the station say it
      // is ready for the handover to go on). Any free port binds beside the old process's.
      if (port !== undefined) yield* Effect.promise(() => agents.previousGone);
      const endpoint = yield* Effect.acquireRelease(
        Effect.promise(() => native.bind({ secretKey: key.seed, alpns: [ALPN, RENAMED_ALPN, FORMER_ALPN, PEER_ALPN, FORMER_PEER_ALPN, TOOLS_ALPN, COMMA_ALPN], relayUrls: cloud.state.relays(), discovery: process.env.COMMA_STATION_NO_DISCOVERY !== "1", bindAddr: port === undefined ? undefined : `0.0.0.0:${port}`, salixRelay: true })),
        // iroh closes gracefully, waiting on every connection (the keepers' too): up to ~12 s. A station stopping or
        // handing over doesn't wait that long: a second, then it is gone (clients reconnect, as they do anyway).
        (endpoint) => Effect.ignore(Effect.timeoutOption(Effect.promise(() => endpoint.close()), "1 second")),
      );
      log.info("mesh", "mesh listening", { station: endpoint.id(), workspace: cloud.state.state!.workspace_name, sockets: endpoint.sockets() });
      yield* Effect.forkScoped(keepRelays(endpoint));
      yield* Effect.forkScoped(followReach(endpoint, cloud.state));
      // Packets for Salix go out on the connector's connection to it (salix-relay.ts).
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
      const superseded = new Superseded();
      for (;;) {
        const conn = yield* Effect.promise(() => endpoint.accept());
        if (!conn) return;
        if (conn.alpn().equals(COMMA_ALPN)) void superseded.arrived(conn);
        yield* FiberSet.run(
          connections,
          Effect.tryPromise(() =>
            conn.alpn().equals(PEER_ALPN) || conn.alpn().equals(FORMER_PEER_ALPN) ? servePeer(conn, cloud.state, agents.remote)
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
