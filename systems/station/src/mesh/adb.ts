// Phones lent to this station's agents (docs/adb-share.md; the Rust station's adb.rs): a phone offers its adbd over its
// member link, and the station reaches it at `127.0.0.1:<port>`, a listener of its own whose every TCP connection is a
// stream it opens on the phone's connection (the phone's core takes it on to adbd). `adb connect` as the offer comes,
// `adb disconnect` as it goes; `adb pair` through the phone's pairing port when its person types the code. The agents
// read who lent what with the `adb_devices` tool (`Shares.list`, given to tools/adb.ts `adbTools`).
//
// Wire (unchanged from the Rust station; the phone's core is released): a request stream whose head line has an
// `"adb"` object. `op: "share"` is an offer, answered `{status: 200, headers: {content-type: application/x-ndjson}}`
// and then a `{serial, adb, message}` line each time how adb holds the phone changes, for as long as the stream lasts;
// `op: "pair" | "grant"` is an ask, answered with a status and `{message}`. Tunnels are streams the station opens on the
// offer's connection: `{"tunnel": "connect" | "pair"}`, the phone's `{ok: true}` (or `{error}`), then bytes both ways.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import net from "node:net";
import { delimiter, join } from "node:path";
import { Clock, Effect, Exit, FiberSet, Scope } from "effect";
import { langOfCore } from "../api/request.ts";
import { wall } from "../ops/fibers.ts";
import { type Lang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import type { Viewer } from "./credential.ts";
import type { Connection, Stream } from "./native.ts";
import { Reader, writeLine } from "./serve.ts";

type Json = any;

/// Where a phone's port is looked for first: the same phone gets the same one while it is free, so what an agent
/// wrote down of it (`adb -s 127.0.0.1:37xxx`) holds across offers.
export const PORTS = { start: 37000, end: 38000 };
/// How long the phone has to take a tunnel stream and reach its adbd.
const TUNNEL_OPEN = 10_000;
/// How long adb has to answer: a look at its state, and what reaches the phone (`connect`, `pair`, `shell`).
const ADB_QUICK = 5_000;
const ADB_TIMEOUT = 30_000;
/// How long a phone whose offer ended is kept for another offer of it (the pairing port opened, a new link): its port
/// and what adb holds of it stay.
export const GRACE = 5_000;
/// How long a connected phone's state is looked at before it is taken as it is (adb says `offline` a moment first).
export const SETTLE = 6_000;

export type AdbState = { serial: string; adb: string; message: string };

export type SharesOptions = {
  /// Whether the station was removed from its workspace, and who hears when that changes (cloud/state.ts `Cloud`):
  /// offers end then, without GRACE.
  cloud?: { removed(): boolean; listen(f: () => void): () => void };
  /// Where adb is (default: `adbPath`, looked for anew each time as the Rust station does).
  adb?: () => string | null;
  /// The clock GRACE and SETTLE are waited out on (a TestClock in tests).
  clock?: Clock.Clock;
  /// How long adb is given, on the machine's time: to answer (`quick`), to connect or pair (`long`). Null: as long as
  /// it takes (a test's fake adb, which always answers, so what it says never turns on how fast the machine is).
  limits?: { quick: number | null; long: number | null };
};

let nextOffer = 1;

/// One phone, as its latest offer has it.
export class Share {
  readonly port: number;
  readonly owner: Viewer;
  /// What the phone says it is: `device`, `android`, `package`; `adbd` (Wireless debugging is on) and `pair` (its
  /// pairing port is open).
  info: { device: string; android: string; package: string; adbd: boolean; pair: boolean };
  /// The connection its latest offer came on: where its tunnels go.
  conn: Connection;
  /// The language its latest offer asked in: what the phone is told of it is said in it.
  lang: Lang;
  /// Which offer it is: one that ended after another came does not take the phone away.
  offer: number;
  /// How the station's adb holds the phone, as the offer's stream is told; `version` counts its changes.
  state: AdbState;
  version = 0;
  /// Why the phone last turned a tunnel down (its adbd not there, say): what adb not getting in is put down to.
  refused: string | null = null;
  readonly server: net.Server;
  private waiters: (() => void)[] = [];

  constructor(server: net.Server, owner: Viewer, info: Share["info"], conn: Connection, lang: Lang, offer: number) {
    this.server = server;
    this.port = (server.address() as net.AddressInfo).port;
    this.owner = owner;
    this.info = info;
    this.conn = conn;
    this.lang = lang;
    this.offer = offer;
    this.state = { serial: this.serial(), adb: "connecting", message: "" };
  }

  serial(): string {
    return `127.0.0.1:${this.port}`;
  }

  set(adb: string, message = "") {
    this.state = { serial: this.serial(), adb, message: message.trim() };
    this.version++;
    const waiters = this.waiters;
    this.waiters = [];
    for (const f of waiters) f();
  }

  /// Resolves at the next `set`.
  changed(): Promise<"changed"> {
    return new Promise((resolve) => this.waiters.push(() => resolve("changed")));
  }

  /// What the agents are told of it (`adb_devices`).
  listed(): Json {
    return {
      serial: this.serial(),
      device: this.info.device,
      android: this.info.android,
      owner: { name: this.owner.name, email: this.owner.email },
      adb: this.state.adb,
      message: this.state.message,
    };
  }
}

/// The phones offered now, by whose and which (`key`).
export class Shares {
  readonly byKey = new Map<string, Share>();
  readonly options: SharesOptions;
  readonly limits: { quick: number | null; long: number | null };
  private stopping = false;
  private stopWaiters: (() => void)[] = [];
  /// Its waits, on its clock; they end as it closes.
  private scope: Scope.Closeable;
  readonly run: <A>(effect: Effect.Effect<A>) => Promise<A>;

  constructor(options: SharesOptions = {}) {
    this.options = options;
    this.limits = options.limits ?? { quick: ADB_QUICK, long: ADB_TIMEOUT };
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, any, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
  }

  /// The phones offered now, for the `adb_devices` tool: `{serial, device, android, owner: {name, email}, adb, message}`.
  list(): Json[] {
    return [...this.byKey.values()].map((s) => s.listed());
  }

  adb(): string | null {
    return (this.options.adb ?? adbPath)();
  }

  /// The station stopping or handing over: listeners closed, offers ended without telling adb (the next station takes
  /// the phones on at the same ports as their offers come again).
  async close() {
    this.stopping = true;
    for (const f of this.stopWaiters.splice(0)) f();
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
    const servers = [...this.byKey.values()].map((s) => s.server);
    this.byKey.clear();
    await Promise.all(servers.map((s) => new Promise<void>((resolve) => s.close(() => resolve()))));
  }

  /// Resolves "stopping" once `close` is called.
  stopped(): Promise<"stopping"> {
    if (this.stopping) return Promise.resolve("stopping");
    return new Promise((resolve) => this.stopWaiters.push(() => resolve("stopping")));
  }

  get isStopping() {
    return this.stopping;
  }
}

/// Which phone of whose an offer or ask is about: the phone's device key as it says (`phone`; its link may be on one
/// of its other keys, one per relay), else the connection's.
export function key(viewer: Viewer, conn: Connection, ask: Json): string {
  const phone = typeof ask?.phone === "string" && /^[0-9a-fA-F]{64}$/.test(ask.phone) ? ask.phone : null;
  return `${viewer.sub}/${phone ?? conn.remoteId()}`;
}

/// A stream whose head says `"adb"` (serve.ts dispatches it after the path check, before a socket's): an offer, held
/// as long as the stream is, or an ask about the phone's offer. The phone finished its send side; nothing is read.
export async function answerAdb(shares: Shares, conn: Connection, viewer: Viewer, head: Json, stream: Stream, _reader?: Reader): Promise<void> {
  const ask = head.adb ?? {};
  const device = key(viewer, conn, ask);
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(head.headers ?? {})) if (typeof v === "string") headers[k] = v;
  const asked = langOfCore(headers);
  const reply = async (status: number, message: string) => {
    await writeLine(stream, { status, headers: { "content-type": "application/json" } });
    await stream.write(Buffer.from(JSON.stringify({ message })));
    await stream.finish();
  };
  const op = ask.op;
  if (op === "share") return offer(shares, conn, viewer, device, ask, asked, stream);
  if (op === "pair" || op === "grant") {
    const share = shares.byKey.get(device);
    if (!share) return reply(409, tr(asked, "station.adb.notSharing"));
    let done: { ok: true; message: string } | { ok: false; error: string };
    try {
      const message = op === "pair" ? await pair(shares, share, typeof ask.code === "string" ? ask.code : "", asked) : await grant(shares, share, asked);
      done = { ok: true, message };
    } catch (e) {
      done = { ok: false, error: (e as Error).message };
    }
    log.info("adb", "adb asked", { email: viewer.email, op, done: done.ok ? done.message : `error: ${done.error}` });
    return done.ok ? reply(200, done.message) : reply(422, done.error);
  }
  return reply(400, tr(asked, "station.adb.unknownAsk"));
}

/// An offer: the phone in `shares` (its listener up), adb told, and how adb holds it said down the stream until the
/// phone stops it, its connection goes, or the station is removed. A later offer from the phone takes this one's place.
async function offer(shares: Shares, conn: Connection, viewer: Viewer, device: string, ask: Json, asked: Lang, stream: Stream) {
  const info = {
    device: text(ask.device, 80),
    android: text(ask.android, 20),
    package: typeof ask.package === "string" && isPackage(ask.package) ? ask.package : "",
    adbd: typeof ask.adbd === "boolean" ? ask.adbd : true,
    pair: typeof ask.pair === "boolean" ? ask.pair : false,
  };
  const number = nextOffer++;
  let share = shares.byKey.get(device);
  if (share) {
    share.info = info;
    share.conn = conn;
    share.lang = asked;
    share.offer = number;
  } else {
    const server = await bind(device);
    share = new Share(server, viewer, info, conn, asked, number);
    // Another offer of the same phone may have come while this one bound its port: the first in keeps it.
    const raced = shares.byKey.get(device);
    if (raced || shares.isStopping) {
      server.close();
      if (shares.isStopping) return void stream.reset(0).catch(() => {});
      share = raced!;
      share.info = info;
      share.conn = conn;
      share.lang = asked;
      share.offer = number;
    } else {
      listen(share);
      shares.byKey.set(device, share);
      log.info("adb", "phone offered for adb", { email: viewer.email, port: share.port });
    }
  }
  await writeLine(stream, { status: 200, headers: { "content-type": "application/x-ndjson" } });
  void connect(shares, share).catch(() => {});

  let unlisten = () => {};
  const removed = new Promise<"removed">((resolve) => {
    const cloud = shares.options.cloud;
    if (!cloud) return;
    if (cloud.removed()) return resolve("removed");
    unlisten = cloud.listen(() => cloud.removed() && resolve("removed"));
  });
  const ends = Promise.race([
    stream.stopped().then(() => "stopped" as const),
    conn.closed().then(() => "closed" as const),
    removed,
    shares.stopped(),
  ]);
  let ended: string;
  let seen = -1;
  for (;;) {
    if (share.version !== seen) {
      seen = share.version;
      try {
        await writeLine(stream, share.state);
      } catch {
        ended = "stream";
        break;
      }
      // Changed again while it was written: said at once.
      if (share.version !== seen) continue;
    }
    const next = await Promise.race([share.changed(), ends]);
    if (next !== "changed") {
      ended = next;
      break;
    }
  }
  unlisten();
  if (ended === "stopping") return;
  // Only the latest offer takes the phone away (one that came on another link has it now), and only if no other comes
  // a moment after.
  // (`close` ends the wait.)
  if (ended !== "removed") await shares.run(Effect.sleep(GRACE)).catch(() => {});
  if (!shares.isStopping && share.offer === number && shares.byKey.get(device) === share) {
    shares.byKey.delete(device);
    share.server.close();
    log.info("adb", "phone no longer offered for adb", { email: viewer.email, port: share.port, ended });
    const adb = shares.adb();
    if (adb) await run(adb, ["disconnect", share.serial()], shares.limits.quick).catch(() => {});
  }
  await stream.finish().catch(() => {});
}

/// Each TCP connection to the phone's port, a tunnel on its offer's connection.
function listen(share: Share) {
  share.server.on("connection", (socket) => {
    tunnel(share.conn, "connect", socket).catch((error) => {
      log.info("adb", "adb tunnel ended", { error: (error as Error).message });
      share.refused = (error as Error).message;
    });
  });
}

/// A port of the phone's own: its usual one if free, else any.
export async function bind(device: string): Promise<net.Server> {
  const hash = createHash("sha256").update(device).digest();
  const usual = PORTS.start + (((hash[0] << 8) | hash[1]) % (PORTS.end - PORTS.start));
  // An offer from before (the station handed over to a new one) may hold it a moment yet: tried 5 times, each miss
  // waited 500 ms after.
  const usualOne = Effect.tryPromise(() => listenOn(usual)).pipe(
    Effect.tapError(() => Effect.sleep(500)),
    Effect.retry({ times: 4 }),
    Effect.orElseSucceed(() => null),
  );
  return (await Effect.runPromise(usualOne)) ?? listenOn(0);
}

function listenOn(port: number): Promise<net.Server> {
  return new Promise((resolve, reject) => {
    const server = net.createServer({ pauseOnConnect: true });
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port, exclusive: true }, () => {
      server.off("error", reject);
      server.on("error", (error) => log.info("adb", "adb listener failed", { error: error.message }));
      resolve(server);
    });
  });
}

/// A stream to the phone for `socket`: `{"tunnel": kind}`, the phone's answer once it reached adbd (or why not), then
/// the bytes both ways until either side ends. `signal` ends it at once (the pairing done).
export async function tunnel(conn: Connection, kind: string, socket: net.Socket, signal?: AbortSignal): Promise<void> {
  socket.on("error", () => {});
  let stream: Stream | null = null;
  const abort = () => {
    socket.destroy();
    void stream?.reset(0).catch(() => {});
  };
  signal?.addEventListener("abort", abort, { once: true });
  try {
    stream = await wall.within(TUNNEL_OPEN, conn.openBi(), "the phone did not take the tunnel");
    if (signal?.aborted) return abort();
    await writeLine(stream, { tunnel: kind });
    const reader = new Reader(stream);
    const answer = await wall.within(TUNNEL_OPEN, reader.line(), "the phone did not answer");
    if (answer === null) throw new Error("the phone closed the tunnel");
    if (typeof answer.error === "string") throw new Error(`the phone did not reach adb: ${answer.error}`);
    const s = stream;
    const up = (async () => {
      try {
        for await (const chunk of socket) await s.write(chunk as Buffer);
      } finally {
        await s.finish().catch(() => {});
      }
    })();
    const down = (async () => {
      if (reader.carry.length > 0) await toSocket(socket, reader.carry);
      for (let more = await s.read(); more; more = await s.read()) await toSocket(socket, more);
      socket.end();
    })();
    const [a, b] = await Promise.allSettled([up, down]);
    for (const r of [a, b]) if (r.status === "rejected") throw r.reason;
  } catch (error) {
    // Why is known (to its offer) before adb hears the socket end: its stream's reset is not waited for.
    socket.destroy();
    void stream?.reset(0).catch(() => {});
    throw error;
  } finally {
    signal?.removeEventListener("abort", abort);
  }
}

/// Written to the socket, waiting while it is full (or failing once it is gone).
function toSocket(socket: net.Socket, bytes: Buffer): Promise<void> {
  if (socket.destroyed) return Promise.reject(new Error("the adb connection closed"));
  if (socket.write(bytes)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const done = (error?: Error) => {
      socket.off("drain", drained);
      socket.off("close", closed);
      error ? reject(error) : resolve();
    };
    const drained = () => done();
    const closed = () => done(new Error("the adb connection closed"));
    socket.once("drain", drained);
    socket.once("close", closed);
  });
}

/// `adb connect` to the phone (unless adb holds it already), and how adb holds it then.
async function connect(shares: Shares, share: Share) {
  const speaks = share.lang;
  const adb = shares.adb();
  if (adb === null) return share.set("missing", tr(speaks, "station.adb.install"));
  const serial = share.serial();
  // Nothing to reach: adb is not left trying to (it would, a few times a second).
  if (share.info.adbd === false) {
    await run(adb, ["disconnect", serial], shares.limits.quick).catch(() => {});
    return share.set("off", tr(speaks, "station.adb.wirelessOff"));
  }
  const state = () => run(adb, ["-s", serial, "get-state"], shares.limits.quick).catch(() => "");
  // Held already (another offer: the pairing port opened, a new link): it stays so.
  if ((await state()) === "device") return share.set("connected");
  share.set("connecting");
  share.refused = null;
  // What adb kept of a tunnel gone (the phone's adbd on another port now) goes first.
  await run(adb, ["disconnect", serial], shares.limits.quick).catch(() => {});
  try {
    await run(adb, ["connect", serial], shares.limits.long);
  } catch (error) {
    return share.set("failed", (error as Error).message);
  }
  // adb says `connected to …` for a TLS port it is not paired with too; only its state says whether it got in: looked
  // at every 500 ms until it is `device` or SETTLE is over.
  const now = await shares.run(
    Effect.gen(function* () {
      const started = yield* Clock.currentTimeMillis;
      for (;;) {
        const now = yield* Effect.promise(state);
        if (now === "device" || (yield* Clock.currentTimeMillis) - started >= SETTLE) return now;
        yield* Effect.sleep(500);
      }
    }),
  );
  const refused = share.refused;
  share.refused = null;
  if (now === "device") share.set("connected");
  else if (now === "unauthorized") share.set("unauthorized", tr(speaks, "station.adb.allowPrompt"));
  else if (refused !== null) share.set("failed", refused);
  else share.set("unpaired", tr(speaks, "station.adb.unpaired"));
}

/// `adb pair` through the phone's pairing port (open while its 使用配对码配对设备 dialog is), then connected anew.
async function pair(shares: Shares, share: Share, typed: string, lang: Lang): Promise<string> {
  const code = [...typed].filter((c) => c >= "0" && c <= "9").join("");
  if (code.length !== 6) throw new Error(tr(lang, "station.adb.codeDigits"));
  if (share.info.pair !== true) throw new Error(tr(lang, "station.adb.pairingClosed"));
  const adb = shares.adb();
  if (adb === null) throw new Error(tr(lang, "station.adb.noAdb"));
  // A port for this pairing alone, its one connection the phone's pairing port.
  const server = await listenOn(0);
  const port = (server.address() as net.AddressInfo).port;
  const conn = share.conn;
  const done = new AbortController();
  const timer = shares.limits.long === null ? () => {} : wall.after(shares.limits.long, () => server.close());
  server.once("connection", (socket) => {
    timer();
    server.close();
    tunnel(conn, "pair", socket, done.signal).catch((error) => log.info("adb", "adb pairing tunnel ended", { error: (error as Error).message }));
  });
  let said: string;
  try {
    said = await run(adb, ["pair", `127.0.0.1:${port}`, code], shares.limits.long);
  } finally {
    timer();
    server.close();
    done.abort();
  }
  if (!said.includes("Successfully paired")) throw new Error(tr(lang, "station.adb.pairFailed", { said }));
  void connect(shares, share).catch(() => {});
  return tr(lang, "station.adb.paired");
}

/// Lets the app turn Wireless debugging on itself from now on (`WRITE_SECURE_SETTINGS`), as its person asked.
async function grant(shares: Shares, share: Share, lang: Lang): Promise<string> {
  const pkg = share.info.package;
  if (!pkg) throw new Error(tr(lang, "station.adb.noPackage"));
  const adb = shares.adb();
  if (adb === null) throw new Error(tr(lang, "station.adb.noAdb"));
  const said = await run(adb, ["-s", share.serial(), "shell", "pm", "grant", pkg, "android.permission.WRITE_SECURE_SETTINGS"], shares.limits.long);
  // Quiet is granted; a refusal says why (MIUI and ColorOS want 「USB 调试（安全设置）」 on).
  if (said !== "") throw new Error(tr(lang, "station.adb.grantFailed", { said }));
  return tr(lang, "station.adb.granted");
}

/// The machine's adb: on `PATH`, else the Android SDK's (where Android Studio puts it, whose adb server is likely the
/// one running: another version's client would restart it), else a package manager's (launchd gives the station a
/// short `PATH`).
export function adbPath(): string | null {
  const env = process.env;
  // adb.exe on Windows, and the SDK where Android Studio puts it there (%LOCALAPPDATA%\Android\Sdk).
  const adb = platform.exe("adb");
  // On PATH as a shell finds it (on Windows, with PATHEXT's extensions).
  const onPath = platform.findCommand("adb", env)?.onPath;
  const candidates = [
    ...(onPath ? [onPath] : []),
    ...(env.PATH ?? "").split(delimiter).filter(Boolean).map((d) => join(d, adb)),
    ...[env.ANDROID_HOME, env.ANDROID_SDK_ROOT].filter((d): d is string => !!d).map((d) => join(d, "platform-tools", adb)),
    ...(env.HOME ? [join(env.HOME, "Library/Android/sdk/platform-tools/adb"), join(env.HOME, "Android/Sdk/platform-tools/adb")] : []),
    ...(env.LOCALAPPDATA ? [join(env.LOCALAPPDATA, "Android", "Sdk", "platform-tools", adb)] : []),
    "/opt/homebrew/bin/adb",
    "/usr/local/bin/adb",
    "/usr/bin/adb",
  ];
  return candidates.find((p) => existsSync(p) && statSync(p).isFile()) ?? null;
}

/// What adb says to `args` (out, then err), within `timeout`. Said whatever its exit; fails only if it could not be
/// started or did not answer in time.
export function run(adb: string, args: string[], timeout: number | null): Promise<string> {
  return new Promise((resolve, reject) => {
    // A .cmd (a shim) runs through its script or cmd: Node starts none by itself.
    const r = platform.runnable(adb, args, process.env);
    const child = spawn(r.file, r.args, { stdio: ["ignore", "pipe", "pipe"], windowsHide: true, windowsVerbatimArguments: r.windowsVerbatimArguments });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (b) => out.push(b));
    child.stderr.on("data", (b) => err.push(b));
    const timer =
      timeout === null
        ? () => {}
        : wall.after(timeout, () => {
            child.kill("SIGKILL");
            reject(new Error("adb did not answer in time"));
          });
    child.on("error", (error) => {
      timer();
      reject(error);
    });
    child.on("close", () => {
      timer();
      resolve((Buffer.concat(out).toString() + Buffer.concat(err).toString()).trim());
    });
  });
}

/// A word the phone says of itself, short and on one line.
export function text(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  return [...value].filter((c) => !/\p{Cc}/u.test(c)).slice(0, max).join("");
}

/// An Android package name, as `pm grant` takes it: nothing a shell would read otherwise.
export function isPackage(name: string): boolean {
  return name.length > 0 && name.length <= 200 && /^[A-Za-z0-9._]+$/.test(name);
}


