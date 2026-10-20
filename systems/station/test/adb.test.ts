// Phones lent to the station's agents (mesh/adb.ts, from the Rust station's adb.rs): the Rust tests, the offer's states
// and asks over in-memory streams, and an offer from a fake phone over a connection in memory, its tunnels reaching
// the phone, with a fake adb (test/fake/adb) — never a real device.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Clock, Duration, Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { GRACE, PORTS, SETTLE, Shares, answerAdb, bind, isPackage, text } from "../src/mesh/adb.ts";
import type { Viewer } from "../src/mesh/credential.ts";
import type { Connection, Stream } from "../src/mesh/native.ts";
import { Reader, writeLine } from "../src/mesh/serve.ts";
import { exe, script } from "./accounts-fakes.ts";

const FAKE = fileURLToPath(new URL("./fake", import.meta.url));
process.env.PATH = `${FAKE}${delimiter}${process.env.PATH ?? ""}`;
const viewer: Viewer = { sub: "u1", email: "pat@example.com", name: "Pat", role: "member", workspace: "ws", device: "d" };
// A phone of this run's own: its offers listen on its usual port (`bind`, from its key), which another run of these
// tests at once on this machine would otherwise share, each one's adb and tunnels reaching the other's.
const PHONE = randomBytes(32).toString("hex");

/// The fake adb always answers: it is given as long as it takes, so what it says never turns on the machine's speed.
const UNLIMITED = { quick: null, long: null };

/// A fresh FAKE_ADB_DIR: what the fake adb was asked, and what it says; `path`, an adb of its own for a `Shares`. Not
/// the process's environment: an adb a test before still runs (its background `connect` after a pairing, say) would
/// then ask this one's.
function fakeAdb(files: Record<string, string> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "fake-adb-"));
  const path = join(dir, "adb");
  script(path, `FAKE_ADB_DIR='${dir}' exec '${join(FAKE, "adb")}' "$@"`);
  for (const [name, content] of Object.entries(files)) writeFileSync(join(dir, name), content);
  const lines = (name: string) => {
    try {
      return readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean);
    } catch {
      return [];
    }
  };
  return { path: exe(path), calls: () => lines("calls").map((l) => JSON.parse(l) as string[]), dialed: () => lines("dialed") };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `what` gives something: what a real process or connection does has no event here. No
/// deadline (it comes, however slow the machine, or the test hangs).
async function until<T>(what: () => T | undefined | null | false): Promise<T> {
  for (;;) {
    const got = what();
    if (got) return got;
    await sleep(20);
  }
}

const turn = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};

/// A TestClock for a `Shares`, which also says when a wait on it begins: `asleep(ms)` resolves once the next wait begun
/// (in the order they began) is there, and fails if it is not of `ms`; `adjust(ms)` moves the clock on.
function testClock() {
  const scope = Effect.runSync(Scope.make());
  const test = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const begun: number[] = [];
  let heard: (() => void) | null = null;
  const clock: Clock.Clock = {
    ...test,
    sleep: (d) =>
      Effect.suspend(() => {
        begun.push(Duration.toMillis(d));
        heard?.();
        return test.sleep(d);
      }),
  };
  let seen = 0;
  const asleep = async (ms: number) => {
    while (seen === begun.length) await new Promise<void>((r) => (heard = r));
    heard = null;
    assert.equal(begun[seen++], ms, "the wait begun");
    // Its sleep is on the clock once the fiber that began it has gone on.
    await turn();
  };
  const adjust = (ms: number) => Effect.runPromise(test.adjust(ms));
  const close = () => Effect.runPromise(Scope.close(scope, Exit.void));
  return { clock, asleep, adjust, close };
}

/// A stream's other end in memory: what the station wrote, and stopping it as a phone that stops reading.
class Memory {
  raw = "";
  finished = false;
  private stop!: () => void;
  private stopping = new Promise<void>((r) => (this.stop = r));
  async read() {
    return null;
  }
  async write(bytes: Buffer) {
    this.raw += bytes.toString();
  }
  async finish() {
    this.finished = true;
  }
  stopped() {
    return this.stopping;
  }
  async reset() {
    this.stop();
  }
  lines(): any[] {
    return this.raw.split("\n").filter(Boolean).map((l) => JSON.parse(l));
  }
}
const nowhere = { remoteId: () => "ef".repeat(32), closed: () => new Promise<string>(() => {}), openBi: async () => Promise.reject(new Error("no streams here")) } as unknown as Connection;
const asking = (adb: any, headers: Record<string, string> = {}) => ({ method: "POST", path: "/admin/api/adb", headers, adb });

test("takes only plain package names", () => {
  assert.ok(isPackage("fail.still.android.beta"));
  assert.ok(!isPackage("fail.still.android; rm -rf /"));
  assert.ok(!isPackage(""));
});

test("gives a phone its usual port while it is free", async () => {
  // A phone of this run's own (another run at once would hold the same usual port).
  const phone = randomBytes(8).toString("hex");
  const first = await bind(phone);
  const port = (first.address() as net.AddressInfo).port;
  assert.ok(port >= PORTS.start && port < PORTS.end);
  await new Promise((r) => first.close(r));
  const again = await bind(phone);
  assert.equal((again.address() as net.AddressInfo).port, port);
  again.close();
});

test("says of itself only one short line", () => {
  assert.equal(text("Pixel\n8", 80), "Pixel8");
  assert.equal(text("x".repeat(100), 80).length, 80);
  assert.equal(text(3, 80), "");
});

test("an ask about no offer, or an unknown one, is answered in the asker's language", async () => {
  const shares = new Shares();
  const unknown = new Memory();
  await answerAdb(shares, nowhere, viewer, asking({ op: "what" }), unknown as unknown as Stream);
  assert.deepEqual(unknown.lines(), [{ status: 400, headers: { "content-type": "application/json" } }, { message: "不认识的 adb 请求" }]);
  assert.ok(unknown.finished);
  const none = new Memory();
  await answerAdb(shares, nowhere, viewer, asking({ op: "pair", code: "123456", phone: PHONE }, { "stillfail-lang": "en" }), none as unknown as Stream);
  assert.deepEqual(none.lines(), [{ status: 409, headers: { "content-type": "application/json" } }, { message: "This phone isn't sharing for debugging" }]);
});

test("without adb the offer says missing; a phone the station cannot reach says why", async () => {
  const time = testClock();
  const missing = new Shares({ adb: () => null, clock: time.clock });
  const stream = new Memory();
  const offered = answerAdb(missing, nowhere, viewer, asking({ op: "share", phone: PHONE, device: "Pixel 8" }), stream as unknown as Stream);
  const said = await until(() => stream.lines().find((l) => l.adb === "missing"));
  assert.match(said.serial, /^127\.0\.0\.1:\d+$/);
  assert.equal(said.message, "这台 station 上没有 adb：装上 Android platform-tools（macOS：brew install android-platform-tools），再重新共享");
  assert.deepEqual(stream.lines()[0], { status: 200, headers: { "content-type": "application/x-ndjson" } });
  assert.deepEqual(missing.list(), [{ serial: said.serial, device: "Pixel 8", android: "", owner: { name: "Pat", email: "pat@example.com" }, adb: "missing", message: said.message }]);
  await stream.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await offered;
  assert.deepEqual(missing.list(), []);
  assert.ok(stream.finished);

  // Its tunnel refused (here: no stream on the connection), adb not getting in is put down to that.
  const adb = fakeAdb();
  const shares = new Shares({ adb: () => adb.path, limits: UNLIMITED, clock: time.clock });
  const failing = new Memory();
  const offer = answerAdb(shares, nowhere, viewer, asking({ op: "share", phone: PHONE }), failing as unknown as Stream);
  // Not in yet after `connect`: its state looked at again after 500 ms, and once SETTLE is over taken as it is.
  await time.asleep(500);
  assert.equal(failing.lines().find((l) => l.adb === "failed"), undefined);
  await time.adjust(SETTLE);
  const failed = await until(() => failing.lines().find((l) => l.adb === "failed"));
  assert.equal(failed.message, "no streams here");
  assert.ok(adb.calls().some((c) => c[0] === "connect" && c[1] === failed.serial));
  await failing.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await offer;
  await until(() => adb.calls().filter((c) => c[0] === "disconnect").length === 2);
  await time.close();
});

test("Wireless debugging off: adb is not left trying, and the offer says so", async () => {
  const adb = fakeAdb();
  const time = testClock();
  const shares = new Shares({ adb: () => adb.path, limits: UNLIMITED, clock: time.clock });
  const stream = new Memory();
  const offer = answerAdb(shares, nowhere, viewer, asking({ op: "share", phone: PHONE, adbd: false }, { "stillfail-lang": "en-US" }), stream as unknown as Stream);
  const off = await until(() => stream.lines().find((l) => l.adb === "off"));
  assert.equal(off.message, "Wireless debugging is off on the phone");
  assert.deepEqual(adb.calls(), [["disconnect", off.serial]]);
  await stream.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await offer;
  await time.close();
});

test("a newer offer of the same phone takes the older's place, its port and all", async () => {
  const time = testClock();
  const shares = new Shares({ adb: () => null, clock: time.clock });
  const first = new Memory();
  const second = new Memory();
  const one = answerAdb(shares, nowhere, viewer, asking({ op: "share", phone: PHONE, device: "A" }), first as unknown as Stream);
  const a = await until(() => first.lines().find((l) => l.adb));
  const two = answerAdb(shares, nowhere, viewer, asking({ op: "share", phone: PHONE, device: "B", pair: true }), second as unknown as Stream);
  const b = await until(() => second.lines().find((l) => l.adb));
  assert.equal(a.serial, b.serial);
  assert.deepEqual(shares.list().map((p) => p.device), ["B"]);
  // The older one ending does not take the phone away.
  await first.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await one;
  assert.deepEqual(shares.list().map((p) => p.device), ["B"]);
  await second.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await two;
  assert.deepEqual(shares.list(), []);
  // Another person's phone with the same key is another phone.
  const theirs = new Memory();
  const three = answerAdb(shares, nowhere, { ...viewer, sub: "u2" }, asking({ op: "share", phone: PHONE }), theirs as unknown as Stream);
  await until(() => theirs.lines().find((l) => l.adb));
  assert.equal(shares.list().length, 1);
  await theirs.reset();
  await time.asleep(GRACE);
  await time.adjust(GRACE);
  await three;
  await time.close();
});

test("the station removed from its workspace ends offers at once", async () => {
  const adb = fakeAdb();
  let removed = false;
  const listeners = new Set<() => void>();
  const time = testClock();
  const shares = new Shares({ adb: () => adb.path, limits: UNLIMITED, clock: time.clock, cloud: { removed: () => removed, listen: (f) => (listeners.add(f), () => listeners.delete(f)) } });
  const stream = new Memory();
  const offer = answerAdb(shares, nowhere, viewer, asking({ op: "share", phone: PHONE }), stream as unknown as Stream);
  await time.asleep(500);
  await time.adjust(SETTLE);
  await until(() => stream.lines().find((l) => l.adb === "failed"));
  removed = true;
  for (const f of listeners) f();
  // Not GRACE: the clock is not moved on.
  await offer;
  assert.deepEqual(shares.list(), []);
  assert.deepEqual(adb.calls().at(-1)?.[0], "disconnect");
  await time.close();
});

// ---- Over a connection in memory, as the mesh carries one: streams opened by either end, each a pair of ordered byte
// streams. (A real QUIC connection on 127.0.0.1 can be lost when the machine is loaded; what is tested here is the
// offer, its tunnels and asks, not the transport, which the mesh's own tests cover.)

/// One end of a stream in memory; what it writes, its `peer` reads.
class End implements Stream {
  peer!: End;
  private queue: (Buffer | null)[] = [];
  private waiting: ((b: Buffer | null) => void) | null = null;
  private broken = false;
  private stop!: () => void;
  private stopping = new Promise<void>((r) => (this.stop = r));
  take(b: Buffer | null) {
    const w = this.waiting;
    this.waiting = null;
    if (w) w(b);
    else this.queue.push(b);
  }
  async read() {
    if (this.queue.length > 0) return this.queue.shift()!;
    if (this.broken) return null;
    return new Promise<Buffer | null>((r) => (this.waiting = r));
  }
  async write(bytes: Buffer) {
    if (this.broken) throw new Error("stream reset");
    this.peer.take(Buffer.from(bytes));
  }
  async finish() {
    this.peer.take(null);
  }
  stopped() {
    return this.stopping;
  }
  /// Stops reading (and sending): the other end's writes fail from then, and it hears so.
  async reset() {
    for (const end of [this, this.peer]) {
      end.broken = true;
      end.take(null);
    }
    this.peer.stop();
  }
}

/// Two ends of a connection: what one opens, the other accepts.
function connected(stationId: string, phoneId: string): [Connection, Connection] {
  const make = (id: string) => {
    const incoming: (Stream | null)[] = [];
    let waiting: ((s: Stream | null) => void) | null = null;
    let closed = false;
    const conn = {
      other: null as any,
      give(s: Stream | null) {
        const w = waiting;
        waiting = null;
        if (w) w(s);
        else incoming.push(s);
      },
      remoteId: () => id,
      alpn: () => Buffer.from("stillfail/admin/1"),
      via: () => null,
      acceptBi: async () => (incoming.length > 0 ? incoming.shift()! : closed ? null : new Promise<Stream | null>((r) => (waiting = r))),
      openBi: async () => {
        if (closed) throw new Error("connection lost");
        const [mine, theirs] = [new End(), new End()];
        mine.peer = theirs;
        theirs.peer = mine;
        conn.other.give(theirs);
        return mine;
      },
      close: () => {
        closed = true;
        conn.give(null);
      },
      isClosed: () => closed,
      closed: () => new Promise<string>(() => {}),
    };
    return conn;
  };
  // Each end's remoteId is the other's.
  const [atStation, toStation] = [make(phoneId), make(stationId)];
  atStation.other = toStation;
  toStation.other = atStation;
  return [atStation as unknown as Connection, toStation as unknown as Connection];
}

/// A station and a phone over a connection in memory: the station's side answering `adb` requests, the phone's taking
/// tunnels to an "adbd" that answers each line `phone:<line>` (or turning them down).
async function link(shares: Shares) {
  const [atStation, toStation] = connected("ab".repeat(32), "cd".repeat(32));
  void (async () => {
    for (let s = await atStation.acceptBi(); s; s = await atStation.acceptBi()) {
      const stream = s;
      const reader = new Reader(stream);
      void reader.line().then((head) => answerAdb(shares, atStation, viewer, head, stream, reader)).catch(() => {});
    }
  })();
  const tunnels: string[] = [];
  const phoneSide = { refuse: null as string | null };
  void (async () => {
    for (let s = await toStation.acceptBi(); s; s = await toStation.acceptBi()) {
      const stream = s;
      void (async () => {
        const reader = new Reader(stream);
        const head = await reader.line();
        tunnels.push(head.tunnel);
        if (phoneSide.refuse !== null) {
          await writeLine(stream, { error: phoneSide.refuse });
          return stream.finish();
        }
        await writeLine(stream, { ok: true });
        let carry = reader.carry.toString();
        for (;;) {
          for (let at = carry.indexOf("\n"); at >= 0; at = carry.indexOf("\n")) {
            await stream.write(Buffer.from(`phone:${carry.slice(0, at)}\n`));
            carry = carry.slice(at + 1);
          }
          const more = await stream.read();
          if (more === null) break;
          carry += more.toString();
        }
        await stream.finish();
      })().catch(() => {});
    }
  })();
  /// A request from the phone: its head line, its send side finished; what comes back, line by line.
  const ask = async (adb: any, headers: Record<string, string> = {}) => {
    const stream = await toStation.openBi();
    await writeLine(stream, asking(adb, headers));
    await stream.finish();
    return { stream, reader: new Reader(stream) };
  };
  const answer = async (adb: any, headers: Record<string, string> = {}) => {
    const { reader } = await ask(adb, headers);
    const head = await reader.line();
    return { head, body: JSON.parse((await reader.rest()).toString()) };
  };
  return { ask, answer, tunnels, phoneSide, close: async () => [atStation, toStation].forEach((c) => c.close(0, "")) };
}

/// The bytes a TCP connection to `port` hears back to `line`, and whether it then ends.
function through(port: number, line: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    let got = "";
    socket.on("connect", () => socket.write(line));
    socket.on("data", (b) => {
      got += b;
      if (got.endsWith("\n")) socket.end();
    });
    socket.on("error", reject);
    socket.on("close", () => resolve(got));
  });
}

test("a phone offered over the mesh: adb connects through its tunnel, asks reach it, and it goes after GRACE", async () => {
  const adb = fakeAdb();
  const time = testClock();
  const shares = new Shares({ adb: () => adb.path, limits: UNLIMITED, clock: time.clock });
  const mesh = await link(shares);
  try {
    const offer = { op: "share", phone: PHONE, device: "Pixel\n8", android: "14", package: "fail.still.android", adbd: true, pair: true };
    const { stream: offered, reader } = await mesh.ask(offer);
    assert.deepEqual(await reader.line(), { status: 200, headers: { "content-type": "application/x-ndjson" } });
    let state;
    do state = await reader.line();
    while (state.adb !== "connected");
    assert.deepEqual(Object.keys(state), ["serial", "adb", "message"]);
    const serial: string = state.serial;
    const port = Number(serial.split(":")[1]);
    assert.ok(serial.startsWith("127.0.0.1:") && port >= PORTS.start && port < PORTS.end);
    // adb was told, and its connection reached the phone as a tunnel stream, bytes both ways.
    assert.deepEqual(adb.calls().slice(0, 3), [["-s", serial, "get-state"], ["disconnect", serial], ["connect", serial]]);
    assert.deepEqual(adb.dialed(), ["phone:CNXN"]);
    assert.deepEqual(mesh.tunnels, ["connect"]);
    assert.deepEqual(shares.list(), [{ serial, device: "Pixel8", android: "14", owner: { name: "Pat", email: "pat@example.com" }, adb: "connected", message: "" }]);
    // Any TCP connection to its port is another tunnel.
    assert.equal(await through(port, "hello\n"), "phone:hello\n");
    assert.deepEqual(mesh.tunnels, ["connect", "connect"]);

    // Asks: pairing through the phone's pairing port, the grant, in the asker's language.
    const paired = await mesh.answer({ op: "pair", code: "12 34 56", phone: PHONE });
    assert.deepEqual(paired, { head: { status: 200, headers: { "content-type": "application/json" } }, body: { message: "配对好了" } });
    assert.ok(adb.dialed().includes("phone:PAIR 123456"));
    assert.ok(mesh.tunnels.includes("pair"));
    assert.ok(adb.calls().some((c) => c[0] === "pair" && c[2] === "123456"));
    // Paired, it connects anew in the background: its offer says so once that is over (before the phone goes, which
    // would otherwise find it under way).
    do state = await reader.line();
    while (state.adb !== "connected");
    const wrong = await mesh.answer({ op: "pair", code: "12345", phone: PHONE }, { "stillfail-lang": "en" });
    assert.deepEqual(wrong, { head: { status: 422, headers: { "content-type": "application/json" } }, body: { message: "The pairing code is 6 digits" } });
    const granted = await mesh.answer({ op: "grant", phone: PHONE });
    assert.deepEqual(granted.body, { message: "以后 app 可以自己打开无线调试了" });
    assert.ok(adb.calls().some((c) => c.join(" ") === `-s ${serial} shell pm grant fail.still.android android.permission.WRITE_SECURE_SETTINGS`));

    // The phone stops reading the offer: the phone is kept for GRACE, then adb lets it go and its port closes.
    const disconnects = () => adb.calls().filter((c) => c[0] === "disconnect").length;
    const before = disconnects();
    await offered.reset(0);
    await time.asleep(GRACE);
    await time.adjust(GRACE - 1);
    await turn();
    assert.equal(disconnects(), before, "not before GRACE");
    assert.equal(shares.list().length, 1, "not before GRACE");
    await time.adjust(1);
    await until(() => disconnects() === before + 1);
    assert.deepEqual(adb.calls().at(-1), ["disconnect", serial]);
    assert.deepEqual(shares.list(), []);
    await assert.rejects(through(port, "x\n"), /ECONNREFUSED/);
  } finally {
    await shares.close();
    await mesh.close();
    await time.close();
  }
});

test("over the mesh: a phone adb is not paired with, or whose adbd turned the tunnel down", async () => {
  const adb = fakeAdb({ "on-connect": "offline" });
  const time = testClock();
  const shares = new Shares({ adb: () => adb.path, limits: UNLIMITED, clock: time.clock });
  const mesh = await link(shares);
  try {
    const { stream, reader } = await mesh.ask({ op: "share", phone: PHONE }, { "stillfail-lang": "en" });
    // `offline` after `connect`: looked at again until SETTLE is over.
    await time.asleep(500);
    await time.adjust(SETTLE);
    await reader.line();
    let state;
    do state = await reader.line();
    while (state.adb === "connecting");
    assert.deepEqual(state, { serial: state.serial, adb: "unpaired", message: "This station isn't paired with the phone yet" });
    assert.deepEqual(adb.dialed(), ["phone:CNXN"]);
    await stream.reset(0);
    await time.asleep(GRACE);
    await time.adjust(GRACE);

    // A new offer (another link, say) after adb forgot it: the phone's adbd is not there.
    await until(() => shares.list().length === 0);
    mesh.phoneSide.refuse = "connection refused";
    const again = await mesh.ask({ op: "share", phone: PHONE });
    await time.asleep(500);
    await time.adjust(SETTLE);
    await again.reader.line();
    do state = await again.reader.line();
    while (state.adb === "connecting");
    assert.deepEqual(state, { serial: state.serial, adb: "failed", message: "the phone did not reach adb: connection refused" });
    await again.stream.reset(0);
  } finally {
    await shares.close();
    await mesh.close();
    await time.close();
  }
});
