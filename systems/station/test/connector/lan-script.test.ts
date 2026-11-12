// lan_script on the station: the runtime's own selftest (the same file the firmware's host test runs), and the
// built-in skills' Gree and miIO scripts against devices on loopback written apart from them (after the protocol
// references, with greeclimate's and python-miio's packets). These use real loopback sockets, so their timeouts run on
// the live clock (README, Determinism).
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createCipheriv, createDecipheriv, createHash } from "node:crypto";
import { createSocket, type Socket } from "node:dgram";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { Effect, Exit } from "effect";
import { lanHttpRequest } from "../../src/connector/lan-gateway.ts";
import { lanScript } from "../../src/connector/lan-script.ts";

const repo = new URL("../../../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, repo), "utf8");
const GREE = read("resources/salix-system-files/skills/gree-ac/gree.js");
const MIIO = read("resources/salix-system-files/skills/miio-lights/miio.js");

const closers: Array<() => void> = [];
after(() => closers.forEach((close) => close()));

type Outcome = { result?: any; error?: string; logs: string[] };
const run = async (source: string, args: unknown, timeout_ms = 10_000) => (await Effect.runPromise(lanScript({ source, args, timeout_ms }))) as Outcome;

/** A UDP device on loopback: `answer` returns the replies to one datagram. */
function device(answer: (datagram: Buffer) => Buffer[]): Promise<number> {
  const socket: Socket = createSocket("udp4");
  closers.push(() => socket.close());
  socket.on("message", (msg, from) => {
    for (const reply of answer(msg)) socket.send(reply, from.port, from.address);
  });
  return new Promise((resolve) => socket.bind(0, "127.0.0.1", () => resolve(socket.address().port)));
}

test("the runtime passes its selftest", async () => {
  const outcome = await run(read("systems/station/native/runner/tests/lan_script_selftest.js"), { n: 1 });
  assert.deepEqual(outcome, { result: "ok", logs: ['selftest {"done":true}'] });
});

test("a script reaches the network through the gateway's udp_request", async () => {
  const port = await device((msg) => [Buffer.concat([msg, Buffer.from(" back")])]);
  const outcome = await run("var r = lan.udp({host: '127.0.0.1', port: args.port, payload_b64: bytes.fromText('hi'), timeout_ms: 500, max_responses: 1});\nreturn bytes.toText(r.responses[0].payload_b64);", { port });
  assert.equal(outcome.result, "hi back");
});

test("a script that throws, runs too long, or calls what the gateway lacks answers with error", async () => {
  assert.match((await run("throw new Error('nope');", {})).error!, /Error: nope/);
  assert.equal((await run("for (;;) {}", {}, 1_000)).error, "the script timed out");
  assert.match((await run("return lan.discover();", {})).error!, /this gateway has no lan_discover/);
  assert.match((await run("return lan.http({url: 'http://127.0.0.1:1/', response_mode: 'chunks'});", {})).error!, /response_mode/);
});

test("bad params are refused before a runner starts", async () => {
  for (const params of [{}, { source: "" }, { source: "x".repeat(64 * 1024 + 1) }]) {
    assert.ok(Exit.isFailure(await Effect.runPromiseExit(lanScript(params))));
  }
});

// ── Gree, after greeclimate ──

const MAC = "f4911e7aca59";
const KEY = "Qx7pLm2Zc9Vb4NtK";
const GENERIC = { ecb: "a3K8Bx%2r8Y7#xDh", gcm: "{yxAHAY_Lm6pbC/<" };
const NONCE = Buffer.from([0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5a, 0x51, 0x6c, 0x5e, 0x63, 0x13]);
const AAD = Buffer.from("qualcomm-test");
type Cipher = "ecb" | "gcm";

function seal(pack: object, key: string, cipher: Cipher, extra: object = {}): Buffer {
  const plain = Buffer.from(JSON.stringify(pack));
  if (cipher === "ecb") {
    const c = createCipheriv("aes-128-ecb", key, null);
    return Buffer.from(JSON.stringify({ t: "pack", i: 0, uid: 0, cid: MAC, tcid: "app", pack: Buffer.concat([c.update(plain), c.final()]).toString("base64"), ...extra }));
  }
  const c = createCipheriv("aes-128-gcm", key, NONCE).setAAD(AAD);
  const data = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.from(JSON.stringify({ t: "pack", i: 0, uid: 0, cid: MAC, tcid: "app", pack: data.toString("base64"), tag: c.getAuthTag().toString("base64"), ...extra }));
}

function open(envelope: Record<string, string>, key: string, cipher: Cipher): Record<string, any> {
  const data = Buffer.from(envelope.pack, "base64");
  if (cipher === "ecb") {
    const d = createDecipheriv("aes-128-ecb", key, null);
    return JSON.parse(Buffer.concat([d.update(data), d.final()]).toString());
  }
  const d = createDecipheriv("aes-128-gcm", key, NONCE).setAAD(AAD).setAuthTag(Buffer.from(envelope.tag, "base64"));
  return JSON.parse(Buffer.concat([d.update(data), d.final()]).toString());
}

/** A Gree unit: `scan` is the cipher of its scan reply, `bind` the only one it binds with. */
function greeUnit(options: { scan?: Cipher; bind?: Cipher; emptyVal?: boolean; scanReply?: Buffer; datReply?: Buffer; refuse?: number } = {}) {
  const scanCipher = options.scan ?? "ecb", bindCipher = options.bind ?? "ecb";
  const state: Record<string, number> = { Pow: 0, Mod: 1, SetTem: 26 };
  const sent: Record<string, any>[] = [];
  const answer = (msg: Buffer): Buffer[] => {
    const text = msg.toString();
    if (text === '{"t":"scan"}') {
      return [options.scanReply ?? seal({ t: "dev", cid: MAC, mac: MAC, brand: "gree", model: "gree", name: "Living room", ver: "V1.1.13" }, GENERIC[scanCipher], scanCipher)];
    }
    const envelope = JSON.parse(text);
    const cipher: Cipher = envelope.tag ? "gcm" : "ecb";
    if (envelope.tcid !== MAC) return [];
    if (envelope.i === 1) {
      if (cipher !== bindCipher) return [];
      const bind = open(envelope, GENERIC[cipher], cipher);
      sent.push(bind);
      return [seal({ t: "bindok", mac: MAC, key: KEY, r: 200 }, GENERIC[cipher], cipher)];
    }
    const request = open(envelope, KEY, cipher);
    sent.push(request);
    if (options.refuse) return [seal({ t: "res", mac: MAC, r: options.refuse }, KEY, cipher)];
    if (request.t === "status") {
      return [options.datReply ?? seal({ t: "dat", mac: MAC, r: 200, cols: request.cols, dat: request.cols.map((c: string) => state[c] ?? 0) }, KEY, cipher)];
    }
    request.opt.forEach((c: string, i: number) => (state[c] = request.p[i]));
    return [seal({ t: "res", mac: MAC, r: 200, opt: request.opt, p: request.p, val: options.emptyVal ? [] : request.p }, KEY, cipher)];
  };
  return { answer, state, sent };
}

test("gree.js reads and sets a unit under both ciphers, and binds with GCM after an ECB scan", async () => {
  for (const [scan, bind] of [["ecb", "ecb"], ["gcm", "gcm"], ["ecb", "gcm"]] as const) {
    const unit = greeUnit({ scan, bind });
    const port = await device(unit.answer);
    const set = await run(GREE, { host: "127.0.0.1", port, set: { SetTem: 24, Pow: 1 } });
    assert.deepEqual(set.result, { host: "127.0.0.1", mac: MAC, values: { Pow: 1, SetTem: 24 }, name: "Living room", model: "gree" }, `${scan}/${bind}: ${set.error}`);
    assert.deepEqual(unit.sent.at(-1), { opt: ["Pow", "SetTem"], p: [1, 24], t: "cmd" });
    const status = await run(GREE, { host: "127.0.0.1", port, status: ["Pow", "Mod", "SetTem"] });
    assert.deepEqual(status.result.values, { Pow: 1, Mod: 1, SetTem: 24 });
    assert.deepEqual(unit.sent.at(-1), { cols: ["Pow", "Mod", "SetTem"], mac: MAC, t: "status" });
  }
});

// greeclimate's cipher.py (CipherV1 and CipherV2) made these packs: reading them proves both ciphers against it.
const SCAN_ECB = "gSoGwqIM2nQgxTqjg6mOsDYTa4hdMuh/bBITRDNv7u9TPPR/T0nC0AF6eKvxQE6b047j2v4fDKtZTQ2mEIDD/t8ZgkQZwjnLmDZbSA1+3uury4AytdYm9P8zJPc3obUra/2J+AaCJX8L9TRrtcuvJLPdrG7obL8weXnGvRhFh7ds8+PNZS2+h12w+RUnd+2ZcCcLRQKLl2weGh8LoKX66L7V+TYaEnEbEm2qsWk1iB4KDo8YqhnOqbJatZYxx9jms4wXSFL3ScoMBAI4PY4eAOSvfICx+lQfMAn9a6dk6ys1mps/SBhwApP6S3vWrYe6";
const SCAN_GCM = ["JtoKliwv65S28N6bemsWXstjssMAhBP/MVUxCruIx/3INCFPzwM9aNK19evWD4Ccz7+yUNTuYrJU+JrIJ7yR06PTjU65PBoqfJ4zH7TsNpxU/6ORBpWo2obop5B9rvgIA7zqrHsVV+fHEDX9wAut6DajQD8HnL0yeYTAWK9ehI5rung8T0eoMqe3/xg2Sa3wmeLlUUjOh5z18TDskoEgfnazkHN/3RuC9ZmCJjwiMe05Wb+9wcxmP/lu3+kAoEUJYu+Qsu9p5B2m7lp2NCQ2tS8r0V2DR3II4GxcNF2UWE9huw==", "sVgqZbWC9U4+RjgxA1Oa/Q=="];
const DAT_ECB = "SJNik8sxMGqnJdHUmM9X4dzp4C4LaAz9cPoYY5vwC45Djv5XILPTp8bGRz8+IIKkUR/L5SEVM4PT7edcCAL1qFKIruiDX7oeXoRR792eVM9GDs8eNxnPsEMq+WFpT/T9";
const DAT_GCM = ["r3GR3M7WYyt/HWk82FhKh7wHCruQN6WNq6oO40BRsLZwcdY2ZQyPIqD4gUWkjqj5RI5eqEGN3aP3VuhSsLHhRKVb2VY1DeMyz3hMYDhVqSvwKVdtllRCoQ==", "8QX9vNwGGsXth0QH2CugYg=="];
const envelope = (pack: string, tag?: string) => Buffer.from(JSON.stringify({ t: "pack", i: 1, uid: 0, cid: MAC, pack, ...(tag ? { tag } : {}) }));

test("gree.js reads greeclimate's scan and status replies under both ciphers", async () => {
  for (const [cipher, scanReply, datReply] of [
    ["ecb", envelope(SCAN_ECB), envelope(DAT_ECB)],
    ["gcm", envelope(SCAN_GCM[0]!, SCAN_GCM[1]), envelope(DAT_GCM[0]!, DAT_GCM[1])],
  ] as const) {
    const port = await device(greeUnit({ scan: cipher, bind: cipher, scanReply, datReply }).answer);
    const outcome = await run(GREE, { host: "127.0.0.1", port, status: ["Pow", "SetTem"] });
    assert.deepEqual(outcome.result, { host: "127.0.0.1", mac: MAC, values: { Pow: 1, SetTem: 26 }, name: "Living room", model: "gree" }, `${cipher}: ${outcome.error}`);
  }
});

test("gree.js reads a command reply whose values are in p and whose val is empty", async () => {
  const port = await device(greeUnit({ emptyVal: true }).answer);
  assert.deepEqual((await run(GREE, { host: "127.0.0.1", port, set: { Pow: 1 } })).result.values, { Pow: 1 });
});

test("gree.js says why a unit cannot be used", async () => {
  const silent = await device(() => []);
  assert.match((await run(GREE, { host: "127.0.0.1", port: silent, status: ["Pow"] })).error!, /device_not_answering/);
  const noBind = await device(greeUnit({ scan: "gcm", bind: "ecb" }).answer);
  assert.match((await run(GREE, { host: "127.0.0.1", port: noBind, status: ["Pow"] })).error!, /device_bind_failed/);
  const other = await device(() => [Buffer.from("not json")]);
  assert.match((await run(GREE, { host: "127.0.0.1", port: other, status: ["Pow"] })).error!, /device_reply_malformed/);
  const refusing = await device(greeUnit({ refuse: 401 }).answer);
  assert.match((await run(GREE, { host: "127.0.0.1", port: refusing, set: { SetTem: 99 } })).error!, /device_error: .*401/);
  assert.match((await run(GREE, { host: "127.0.0.1", port: silent, status: ["Pow"], set: { Pow: 1 } })).error!, /bad_args/);
});

// ── miIO, after python-miio ──

// Built independently with Python hashlib and `openssl enc -aes-128-cbc`, after python-miio's build_msg.
const TOKEN = "00112233445566778899aabbccddeeff";
const GET_PROP = Buffer.from(
  "21310060000000000A1B2C3D5F0E1D2CE753A182FEE1474D6A2E2B565DA5BE91" +
    "A5516EC6151955DC2BB2D43E7C84C1833AD6ABD2560C09DE4318B095B7713E23" +
    "66D4BD383C59BDC6C2B0C6191F43F2F2CAAE6E8E38A8CE4E08268E608A56A78C",
  "hex",
);
const md5 = (...parts: Buffer[]) => createHash("md5").update(Buffer.concat(parts)).digest();

function miioPacket(json: string, token: Buffer, deviceId: Buffer, stamp: number): Buffer {
  const key = md5(token), iv = md5(key, token);
  const c = createCipheriv("aes-128-cbc", key, iv);
  const data = Buffer.concat([c.update(Buffer.from(json)), c.final()]);
  const header = Buffer.alloc(16);
  header.writeUInt16BE(0x2131, 0);
  header.writeUInt16BE(32 + data.length, 2);
  deviceId.copy(header, 8);
  header.writeUInt32BE(stamp, 12);
  return Buffer.concat([header, md5(header, token, data), data]);
}

/** A miIO lamp with device id 0A1B2C3D whose stamp reads 0x5F0E1D2B at its hello. */
function lamp(reply: (request: Buffer) => Buffer[]) {
  const commands: Buffer[] = [];
  const answer = (msg: Buffer): Buffer[] => {
    if (msg.length === 32 && msg.subarray(4).every((b) => b === 0xff)) {
      const hello = Buffer.alloc(32, 0);
      hello.writeUInt16BE(0x2131, 0);
      hello.writeUInt16BE(32, 2);
      Buffer.from("0A1B2C3D", "hex").copy(hello, 8);
      hello.writeUInt32BE(0x5f0e1d2b, 12);
      hello.fill(0xff, 16);
      return [hello];
    }
    commands.push(msg);
    return reply(msg);
  };
  return { answer, commands };
}

test("miio.js sends python-miio's packet byte for byte and reads the reply", async () => {
  const token = Buffer.from(TOKEN, "hex");
  const device_ = lamp(() => [miioPacket('{"id":1,"result":["on"]}\u0000', token, Buffer.from("0A1B2C3D", "hex"), 0x5f0e1d2d)]);
  const port = await device(device_.answer);
  const outcome = await run(MIIO, { host: "127.0.0.1", port, token: TOKEN.toUpperCase(), method: "get_prop", params: ["power"], id: 1 });
  assert.deepEqual(outcome.result, { host: "127.0.0.1", result: ["on"] }, outcome.error);
  assert.deepEqual(device_.commands, [GET_PROP]);
});

test("miio.js tolerates NUL padding with bytes after it, and skips other devices' replies", async () => {
  const token = Buffer.from(TOKEN, "hex");
  const port = await device(
    lamp(() => [
      miioPacket('{"id":7,"result":["stale"]}\u0000', token, Buffer.from("0A1B2C3D", "hex"), 1),
      miioPacket('{"id":7,"result":["other"]}\u0000', token, Buffer.from("01020304", "hex"), 1),
      miioPacket('{"id":7,"result":["ok"]}\u0000k', token, Buffer.from("0A1B2C3D", "hex"), 1),
    ].slice(1)).answer,
  );
  const outcome = await run(MIIO, { host: "127.0.0.1", port, token: TOKEN, method: "set_power", params: ["on", "smooth", 500], id: 7 });
  assert.deepEqual(outcome.result, { host: "127.0.0.1", result: ["ok"] }, outcome.error);
});

test("miio.js says why a lamp cannot be used", async () => {
  const token = Buffer.from(TOKEN, "hex");
  const wrong = Buffer.alloc(16);
  const silent = await device(() => []);
  assert.match((await run(MIIO, { host: "127.0.0.1", port: silent, token: TOKEN, method: "get_prop" })).error!, /device_not_answering/);
  const badToken = await device(lamp(() => [miioPacket('{"id":2,"result":[]}\u0000', wrong, Buffer.from("0A1B2C3D", "hex"), 1)]).answer);
  assert.match((await run(MIIO, { host: "127.0.0.1", port: badToken, token: TOKEN, method: "get_prop", id: 2 })).error!, /bad_token/);
  const refusing = await device(lamp(() => [miioPacket('{"id":3,"error":{"code":-5001,"message":"invalid arg"}}\u0000', token, Buffer.from("0A1B2C3D", "hex"), 1)]).answer);
  assert.match((await run(MIIO, { host: "127.0.0.1", port: refusing, token: TOKEN, method: "set_bright", params: [500], id: 3 })).error!, /device_error: .*-5001: invalid arg/);
  const mute = await device(lamp(() => []).answer);
  assert.match((await run(MIIO, { host: "127.0.0.1", port: mute, token: TOKEN, method: "get_prop", id: 4 })).error!, /device_no_reply/);
  assert.match((await run(MIIO, { host: "127.0.0.1", port: silent, token: "short", method: "get_prop" })).error!, /bad_token/);
});

test("a script stopped by its time stops the LAN call it was waiting on", async () => {
  // The call never answers: the script has 1 s. The call's signal must fire when the script ends.
  let stopped!: () => void;
  const callStopped = new Promise<void>((resolve) => (stopped = resolve));
  const hanging = (_method: string, _params: Record<string, unknown>, signal: AbortSignal) => {
    signal.addEventListener("abort", () => stopped());
    return new Promise<never>(() => {});
  };
  const exit = await Effect.runPromiseExit(lanScript({ source: "return lan.udp({host: '127.0.0.1', port: 9, payload_b64: 'aGk='});", timeout_ms: 1_000 }, hanging));
  assert.ok(Exit.isFailure(exit));
  await callStopped;
});

test("a stopped LAN call closes the device's connection", async () => {
  let closed!: () => void;
  const connectionClosed = new Promise<void>((resolve) => (closed = resolve));
  const server = createServer((req) => req.socket.on("close", () => closed()));
  closers.push(() => server.close());
  const port = await new Promise<number>((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
  const stop = new AbortController();
  const request = Effect.runPromiseExit(lanHttpRequest({ method: "GET", url: `http://127.0.0.1:${port}/`, timeout_seconds: 30 }), { signal: stop.signal });
  await new Promise<void>((resolve) => server.once("request", () => resolve()));
  stop.abort();
  assert.ok(Exit.isFailure(await request));
  await connectionClosed;
});

// ── lan.tcp ──

function tcpHost(handle: (socket: import("node:net").Socket) => void): Promise<number> {
  const server = createTcpServer(handle);
  closers.push(() => server.close());
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
}

test("lan.tcp sends, shuts its side and reads what the host answers until it closes", async () => {
  const port = await tcpHost((socket) => {
    const got: Buffer[] = [];
    socket.on("data", (d) => got.push(d));
    socket.on("end", () => socket.end(Buffer.concat([Buffer.from("echo:"), ...got])));
  });
  const outcome = await run("var r = lan.tcp({host: '127.0.0.1', port: args.port, send_b64: bytes.fromText('hi'), close_write: true});\nreturn [bytes.toText(r.data_b64), r.closed, r.truncated, r.timed_out];", { port });
  assert.deepEqual(outcome.result, ["echo:hi", true, false, false], outcome.error);
});

test("lan.tcp stops at max_bytes and when the host goes quiet", async () => {
  const port = await tcpHost((socket) => socket.write(Buffer.alloc(1000, 120)));
  const cut = await run("var r = lan.tcp({host: '127.0.0.1', port: args.port, max_bytes: 100, idle_ms: 200});\nreturn [bytes.length(r.data_b64), r.truncated];", { port });
  assert.deepEqual(cut.result, [100, true], cut.error);
  const quiet = await run("var r = lan.tcp({host: '127.0.0.1', port: args.port, idle_ms: 200});\nreturn [bytes.length(r.data_b64), r.closed, r.timed_out];", { port });
  assert.deepEqual(quiet.result, [1000, false, false], quiet.error);
});

test("lan.tcp says when nothing listens", async () => {
  const port = await tcpHost(() => {});
  const server = closers.pop()!;
  server();
  const outcome = await run("return lan.tcp({host: '127.0.0.1', port: args.port});", { port });
  assert.match(outcome.error!, /refused/);
});

// ── lan-printer/ipp.js, against an IPP printer written from RFC 8010 ──

const IPP = read("resources/salix-system-files/skills/lan-printer/ipp.js");

/** Reads one IPP request's operation and attributes; answers with `status` and the given printer/job groups. */
function ippPrinter(answer: (op: number, attrs: Record<string, string | number>, document: Buffer) => Buffer) {
  const requests: Array<{ op: number; attrs: Record<string, string | number>; document: Buffer; path: string }> = [];
  return {
    requests,
    port: tcpHost((socket) => {
      let data = Buffer.alloc(0);
      socket.on("data", (chunk) => {
        data = Buffer.concat([data, chunk]);
        const end = data.indexOf("\r\n\r\n");
        if (end < 0) return;
        const head = data.subarray(0, end).toString();
        const length = Number(/content-length: (\d+)/i.exec(head)![1]);
        if (data.length < end + 4 + length) return;
        const body = data.subarray(end + 4, end + 4 + length);
        const op = body.readUInt16BE(2);
        const attrs: Record<string, string | number> = {};
        let i = 8;
        while (body[i] !== 0x03) {
          const tag = body[i++]!;
          if (tag < 0x10) continue;
          const nl = body.readUInt16BE(i);
          const name = body.subarray(i + 2, i + 2 + nl).toString();
          i += 2 + nl;
          const vl = body.readUInt16BE(i);
          const value = tag === 0x21 ? body.readInt32BE(i + 2) : body.subarray(i + 2, i + 2 + vl).toString();
          i += 2 + vl;
          if (nl) attrs[name] = value;
        }
        const document = body.subarray(i + 1);
        requests.push({ op, attrs, document, path: head.split(" ")[1]! });
        const reply = answer(op, attrs, document);
        socket.end(Buffer.concat([Buffer.from(`HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: ${reply.length}\r\n\r\n`), reply]));
      });
    }),
  };
}

function ippReply(status: number, groups: Array<[number, Array<[number, string, number | string]>]>): Buffer {
  const parts: Buffer[] = [Buffer.from([2, 0, status >> 8, status & 255, 0, 0, 0, 1])];
  for (const [tag, attrs] of [[1, [[0x47, "attributes-charset", "utf-8"]]] as [number, Array<[number, string, number | string]>], ...groups]) {
    parts.push(Buffer.from([tag]));
    for (const [valueTag, name, value] of attrs) {
      const v = typeof value === "number" ? Buffer.from([value >>> 24, (value >> 16) & 255, (value >> 8) & 255, value & 255]) : Buffer.from(value);
      const n = Buffer.from(name);
      parts.push(Buffer.from([valueTag, n.length >> 8, n.length & 255]), n, Buffer.from([v.length >> 8, v.length & 255]), v);
    }
  }
  parts.push(Buffer.from([3]));
  return Buffer.concat(parts);
}

test("ipp.js prints a document and reads the printer's state", async () => {
  const printer = ippPrinter((op) =>
    op === 0x0002
      ? ippReply(0, [[2, [[0x21, "job-id", 10], [0x23, "job-state", 5]]]])
      : ippReply(0, [[4, [[0x23, "printer-state", 3], [0x44, "printer-state-reasons", "none"], [0x21, "marker-levels", 80], [0x21, "", 45]]]]),
  );
  const port = await printer.port;
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString("base64");
  const printed = await run(IPP, { action: "print", host: "127.0.0.1", port, document: jpeg, copies: 2 });
  assert.deepEqual(printed.result, { job: { "job-id": 10, "job-state": "processing" }, status: "0x0000", ok: true }, printed.error);
  const job = printer.requests[0]!;
  assert.equal(job.path, "/ipp/print");
  assert.deepEqual(
    [job.op, job.attrs["printer-uri"], job.attrs["document-format"], job.attrs.copies, job.attrs["print-color-mode"], job.document.toString("base64")],
    [0x0002, `ipp://127.0.0.1:${port}/ipp/print`, "image/jpeg", 2, "monochrome", jpeg],
  );
  const status = await run(IPP, { action: "status", host: "127.0.0.1", port });
  assert.deepEqual(status.result.printer, { "printer-state": "idle", "printer-state-reasons": "none", "marker-levels": [80, 45] }, status.error);
});

test("ipp.js reports a refused job and a printer that does not answer", async () => {
  const refusing = ippPrinter(() => ippReply(0x040a, []));
  const port = await refusing.port;
  const refused = await run(IPP, { action: "print", host: "127.0.0.1", port, document: "AAE=", format: "application/pdf" });
  assert.deepEqual([refused.result.ok, refused.result.status], [false, "0x040a"], refused.error);
  const silent = await tcpHost((socket) => socket.end());
  assert.match((await run(IPP, { action: "print", host: "127.0.0.1", port: silent, document: "AAE=" })).error!, /printer_no_answer: .*may have been printed/);
});

// ── home-assistant/ha.js ──

test("ha.js calls Home Assistant's REST API with the token", async () => {
  const seen: Array<{ method: string; url: string; auth: string; body: string }> = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      seen.push({ method: req.method!, url: req.url!, auth: req.headers.authorization ?? "", body });
      if (req.headers.authorization !== "Bearer good-token-123") return void res.writeHead(401).end("401: Unauthorized");
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify([{ entity_id: "light.desk", state: "on" }]));
    });
  });
  closers.push(() => server.close());
  const port = await new Promise<number>((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
  const HA = read("resources/salix-system-files/skills/home-assistant/ha.js");
  const called = await run(HA, { host: "127.0.0.1", port, token: "good-token-123", path: "/api/services/light/turn_on", body: { entity_id: "light.desk" } });
  assert.deepEqual(called.result, { status: 200, body: [{ entity_id: "light.desk", state: "on" }] }, called.error);
  assert.deepEqual(seen[0], { method: "POST", url: "/api/services/light/turn_on", auth: "Bearer good-token-123", body: '{"entity_id":"light.desk"}' });
  assert.match((await run(HA, { host: "127.0.0.1", port, token: "stale-token-0", path: "/api/states" })).error!, /bad_token/);
});

// ── home-assistant/ha.py, the computer gateway's ha command, against a Home Assistant stand-in on loopback ──

type Seen = { method: string; url: string; auth: string; body: string };
/** An HTTP server on loopback: `answer` gives status, headers and body for each request it records. */
async function httpServer(answer: (req: Seen) => [number, Record<string, string>, string]) {
  const seen: Seen[] = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      const r = { method: req.method!, url: req.url!, auth: req.headers.authorization ?? "", body };
      seen.push(r);
      const [status, headers, text] = answer(r);
      res.writeHead(status, headers).end(text);
    });
  });
  closers.push(() => server.close());
  const port = await new Promise<number>((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
  return { seen, url: `http://127.0.0.1:${port}` };
}

function ha(url: string, args: string[]): Promise<{ code: number; lines: any[] }> {
  const dir = mkdtempSync(join(tmpdir(), "ha-py-"));
  writeFileSync(join(dir, "token"), "secret-token-1\n");
  writeFileSync(join(dir, "connection.json"), JSON.stringify({ url, token_file: join(dir, "token") }));
  const script = new URL("resources/salix-system-files/skills/home-assistant/ha.py", repo).pathname;
  return new Promise((resolve) =>
    execFile("python3", [script, ...args], { env: { ...process.env, COMMA_HA_CONFIG: join(dir, "connection.json") } }, (error, stdout) =>
      resolve({ code: error ? Number(error.code) : 0, lines: stdout.trim().split("\n").map((l) => JSON.parse(l)) }),
    ),
  );
}

test("ha.py does not send the token to the address a redirect names", async () => {
  const other = await httpServer(() => [200, { "content-type": "application/json" }, "[]"]);
  const home = await httpServer((r) => [302, { location: other.url + r.url }, ""]);
  for (const args of [["entities"], ["catalog"]]) {
    const out = await ha(home.url, args);
    assert.notEqual(out.code, 0, JSON.stringify(out));
    assert.match(out.lines.at(-1).error, /redirected/);
  }
  assert.equal(home.seen[0].auth, "Bearer secret-token-1");
  assert.deepEqual(other.seen, []);
});

test("ha.py call reports the attributes the device shows, not only the values asked", async () => {
  const lamp = { entity_id: "light.desk", state: "on", attributes: { friendly_name: "Desk", brightness: 13, color_mode: "brightness" } };
  const home = await httpServer((r) =>
    r.method === "POST" ? [200, { "content-type": "application/json" }, "[]"] : [200, { "content-type": "application/json" }, JSON.stringify(lamp)],
  );
  const out = await ha(home.url, ["call", "light.turn_on", "light.desk", "brightness_pct=40"]);
  assert.equal(out.code, 0, JSON.stringify(out));
  assert.deepEqual(out.lines[0], { called: "light.turn_on", data: { brightness_pct: 40, entity_id: "light.desk" }, accepted: true });
  assert.deepEqual(out.lines[1], {
    entity_id: "light.desk",
    state: "on",
    name: "Desk",
    attributes: lamp.attributes,
    differs: { brightness_pct: { asked: 40, now: 5 } },
  });
  lamp.attributes.brightness = 102;
  assert.equal((await ha(home.url, ["call", "light.turn_on", "light.desk", "brightness_pct=40"])).lines[1].differs, undefined);
});
