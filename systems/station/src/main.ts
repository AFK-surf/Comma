// The still.fail station, in TypeScript (docs/station-ts.md). This file is the composition root: every part is a layer
// made here and given what it needs (src/services.ts); nothing registers itself anywhere. Stopping the station is
// interrupting it: every part's scope closes, and with it what it opened. Commands as the Rust station takes them:
//
//   run --app DIR [--port N] [--data DIR] [--with-parent] [--launcher-fds a,b,c]
//   enroll <cloud> <token> [--provider stillfail|comma] [--data DIR]   status [--data DIR]   id [--data DIR]
//   restore-archive [--data DIR]
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { Effect, Fiber, Layer, SubscriptionRef } from "effect";
import { enroll, id, status } from "./cli.ts";
import { MeshLive } from "./mesh/mesh.ts";
import { AgentsLive } from "./sessions/agents.ts";
import { dataDir, flag } from "./ops/files.ts";
import { setStationLang } from "./ops/i18n.ts";
import { type Control, launcher } from "./ops/launcher.ts";
import { hearErrors, log } from "./ops/log.ts";
import { ConfigFile } from "./ops/config.ts";
import { ErrorReports, builtKey } from "./ops/telemetry.ts";
import { answer, langOfBrowser } from "./ops/loopback.ts";
import { version } from "./ops/version.ts";
import { AdbShares, AdminApi, AdminHost, ControlPlane, Events, Key, MeshNative, Paths, Readers, Store, Up } from "./services.ts";
import { PROVIDERS, type Provider } from "./cloud/provider.ts";
import { wall } from "./ops/fibers.ts";
import { ConnectorLive } from "./connector/service.ts";
import { SalixRelay } from "./mesh/salix-relay.ts";
import { platform } from "./platform/index.ts";
import { keepRunnerIn } from "./platform/processes.ts";

// Run by the desktop app on its own Electron as Node (apps/desktop/src/station.ts): what this starts (agents, jobs,
// their tools, the next station at a handover through the launcher, which keeps its own) is not told to be Node too.
delete process.env.ELECTRON_RUN_AS_NODE;
// What reads HOME (the machine's logins, its transcripts) finds the user's home there, where the machine names it
// otherwise (Windows: USERPROFILE).
if (!process.env.HOME && platform.home(process.env)) process.env.HOME = platform.home(process.env);

const args = process.argv.slice(2);
const data = dataDir(args);
const command = args.find((a, i) => !a.startsWith("--") && !(i > 0 && args[i - 1].startsWith("--") && args[i - 1] !== "--with-parent"));
/// Flags that take a value: what follows them is no command's argument.
const VALUED = ["--data", "--provider"];

// What it says on this machine is in the station's language (config.json `language`).
try {
  const config = process.env.STILLFAIL_CONFIG || process.env.EMBER_CONFIG || join(data, "config.json");
  setStationLang(JSON.parse(readFileSync(config, "utf8")).language);
} catch {}

function usage(): never {
  console.error("usage: stillfail-station run --app DIR [--port N] [--data DIR] [-- CONNECTOR FLAGS] | comma-client ... | computer-use ACTION [--config PATH] [--json OBJECT] | enroll <cloud> <token> [--provider stillfail|comma] | status | id");
  process.exit(2);
}

/// The loopback port (src/ops/loopback.ts): old page links sent on to still.fail cloud, `/healthz`. The port it got is
/// written to <data>/run/ports.json.
const Loopback = (control: Control) =>
  Layer.effectDiscard(
    Effect.gen(function* () {
      const up = yield* Up;
      const cloud = yield* ControlPlane;
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          const server = createServer((req, res) => {
            const url = new URL(req.url ?? "/", "http://station");
            const s = cloud.state.state;
            const place = s ? { origin: s.origin, workspace: s.workspace, workspace_name: s.workspace_name, station: s.station, removed_at: s.removed_at } : null;
            const reply = answer(url.pathname, url.search ? url.search.slice(1) : null, SubscriptionRef.getUnsafe(up), place, langOfBrowser(req.headers));
            res.writeHead(reply.status, reply.headers).end(reply.body);
          });
          server.on("listening", () => {
            const port = (server.address() as AddressInfo).port;
            // Behind the launcher's entrance, the launcher's port is the one there is (the launcher wrote it too).
            const shown = control.ports?.admin ?? port;
            mkdirSync(join(data, "run"), { recursive: true });
            writeFileSync(join(data, "run", "ports.json"), `{"admin":${shown}}\n`);
            control.serving("admin", port);
            log.info("station", "loopback port listening (old /admin links go to still.fail cloud)", { port: shown });
          });
          if (control.loopbackFd !== undefined) server.listen({ fd: control.loopbackFd });
          else if (control.ports) server.listen(0, "127.0.0.1");
          else {
            // On its own (no launcher): 4760, or a free port when that is taken and none was named (local.rs).
            const named = flag(args, "--port");
            server.on("error", (e: NodeJS.ErrnoException) => {
              if (e.code === "EADDRINUSE" && !named) server.listen(0, "127.0.0.1");
              else log.error("station", "the loopback port is not had", { error: e.message });
            });
            server.listen(Number(named ?? 4760), "127.0.0.1");
          }
          return server;
        }),
        (server) => Effect.sync(() => server.close()),
      );
    }),
  );

function run() {
  const app = flag(args, "--app");
  if (!app) usage();
  const control = launcher(args);
  // Runners (agents', jobs') from copies under the data directory on Windows, out of reach of the app's updater.
  keepRunnerIn(join(data, "run", "bin"));
  // Error lines to still.fail's error tracking, while config.json says so (telemetry.errors) and the build has a key.
  const settings = new ConfigFile(data);
  const reports = new ErrorReports({
    key: builtKey(join(app, "dist", "admin")),
    enabled: () => settings.raw()?.telemetry?.errors === true,
    station: () => {
      try {
        return JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8")).station ?? null;
      } catch {
        return null;
      }
    },
  });
  hearErrors((line, error) => reports.report(line, error));
  const paths = Layer.succeed(Paths)({ data, app });
  const base = Layer.mergeAll(Key.layer, Readers.layer, Store.layer, MeshNative.layer, Up.layer).pipe(Layer.provideMerge(paths));
  const parts = Layer.mergeAll(ControlPlane.layer, SalixRelay.layer).pipe(Layer.provideMerge(base));
  const station = Layer.mergeAll(MeshLive, Loopback(control), ConnectorLive(args)).pipe(
    Layer.provideMerge(AdminApi.layer),
    Layer.provideMerge(AgentsLive(control)),
    Layer.provideMerge(Events.layer),
    Layer.provideMerge(AdminHost.layer),
    Layer.provideMerge(AdbShares.layer),
    Layer.provideMerge(parts),
  );
  const main = Effect.gen(function* () {
    yield* SubscriptionRef.set(yield* Up, true);
    control.ready(version());
    log.info("station", "station up", { version: version(), data });
    // STILLFAIL_MEMLOG: where the memory goes, now and then (for measuring).
    if (process.env.STILLFAIL_MEMLOG) {
      wall.every(10_000, () => {
        const m = process.memoryUsage();
        log.info("memory", "now", Object.fromEntries(Object.entries(m).map(([k, v]) => [k, Math.round(v / 1048576)])));
      });
    }
    return yield* Effect.never;
  }).pipe(Effect.provide(station));
  const fiber = Effect.runFork(main);

  let stopping = false;
  const stop = (why: string) => {
    if (stopping) return;
    stopping = true;
    log.info("station", "stopping", { why });
    Effect.runFork(Fiber.interrupt(fiber)).addObserver(() => void reports.shutdown().finally(() => process.exit(0)));
  };
  control.on("stop", () => stop("asked to stop"));
  control.on("handover", () => stop("handed over to the next station process"));
  fiber.addObserver((exit) => {
    if (!stopping) {
      log.error("station", "the station stopped by itself", { exit: String(exit) });
      process.exit(1);
    }
  });
}

switch (command) {
  case "run":
    run();
    break;
  case "enroll": {
    const [, origin, token] = args.filter((a, i) => !a.startsWith("--") && !(i > 0 && VALUED.includes(args[i - 1])));
    const provider = (flag(args, "--provider") ?? "stillfail") as Provider;
    if (!origin || !token || !PROVIDERS.includes(provider)) usage();
    await enroll(data, origin.replace(/\/+$/, ""), token, provider);
    break;
  }
  case "status":
    console.log(status(data));
    break;
  case "id":
    id(data);
    break;
  // The channel the station is updated on (`stillfail update`): set when one is named, then said.
  case "channel": {
    const { channelCommand } = await import("./updates/channel.ts");
    const code = await channelCommand(args, data);
    if (code === 2) usage();
    process.exitCode = code;
    break;
  }
  // `comma` for the agents (Main's client control API, src/connector/comma-client-cli.ts).
  case "comma-client": {
    const { commaClientCommand } = await import("./connector/cli.ts");
    process.exitCode = await commaClientCommand(args.slice(args.indexOf("comma-client") + 1));
    break;
  }
  // Computer Use, as the app asks for its permissions and the agents for its actions (src/connector/computer-use.ts).
  case "computer-use": {
    const { computerUseCommand } = await import("./connector/cli.ts");
    process.exitCode = await computerUseCommand(args.slice(args.indexOf("computer-use") + 1));
    break;
  }
  // A Workload's Container, before it starts its station: the archive its start names goes onto the disk
  // (src/connector/durable-archive.ts). Run by the image's entrypoint, on this release's Node, with the `--data` it
  // starts the station with; it ends at once with its result, whatever connections to the store are still open.
  case "restore-archive": {
    const { restoreArchiveCommand } = await import("./connector/cli.ts");
    process.exit(await restoreArchiveCommand([], undefined, data));
  }
  default:
    usage();
}
