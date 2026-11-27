import type { Socket } from "node:dgram";
import { EventEmitter } from "node:events";
import { createServer, type ServerResponse } from "node:http";
import os from "node:os";
import { duplexPair } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { testEpoch } from "@comma/test-utils/test-clock";
import { LanUnreachableError, type LanService } from "../modules/airdrop/lan-nearby";
import { createLanNearbyPlatform } from "../modules/airdrop/lan-platform";

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

/**
 * The air between the mDNS sockets of one local network: what one sends, every
 * socket hears a tick later, itself included, as a multicast group does. A
 * refused socket gets the error in place of a send, as Node's does when the
 * network has no route to the group. A socket made with `held` never binds:
 * each try raises that error on it a tick later, as Node's does when another
 * program holds the port. No UDP socket is opened.
 */
function air() {
  const sockets = new Set<EventEmitter>();
  const refused = new Map<Socket, { error: Error; told: () => void }>();
  return {
    /** Settles once the socket has had a send refused. */
    refuse: (socket: Socket, error: Error) =>
      new Promise<void>((told) => refused.set(socket, { error, told })),
    accept: (socket: Socket) => refused.delete(socket),
    socket(held?: Error) {
      const socket = Object.assign(new EventEmitter(), {
        bind(_port: number, _address: string | undefined, bound: () => void) {
          if (held) process.nextTick(() => socket.emit("error", held));
          else bound();
        },
        send(
          message: Buffer,
          _offset: number,
          _length: number,
          port: number,
          _address: string,
          sent: (error: Error | null) => void
        ) {
          const refusal = refused.get(socket);
          process.nextTick(() => {
            if (refusal) {
              try {
                sent(refusal.error);
              } finally {
                refusal.told();
              }
              return;
            }
            for (const heard of sockets)
              heard.emit("message", message, {
                address: "192.0.2.1",
                family: "IPv4",
                port,
                size: message.length,
              });
            sent(null);
          });
        },
        close(closed?: () => void) {
          sockets.delete(socket);
          closed?.();
        },
      }) as unknown as Socket;
      sockets.add(socket);
      return socket;
    },
  };
}
/** What the receiver says it listens on; no socket is opened. */
const fakePort = 8771;
const receiver = { airDrop: undefined, id: "receiver-id", name: "Ada", port: fakePort };

it("stays up when the network refuses an mDNS answer, and is found once it takes them again", async () => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  const net = air();
  const warnings: string[] = [];
  const socket = net.socket();
  const receiving = createLanNearbyPlatform({
    log: { warn: (message) => warnings.push(message) },
    socket,
  });
  const sender = createLanNearbyPlatform({ socket: net.socket() });
  receiving.advertise(receiver);
  // mDNS probes for the name before it answers for it.
  await vi.advanceTimersByTimeAsync(2_000);

  const refused = net.refuse(
    socket,
    Object.assign(new Error("send EHOSTUNREACH 224.0.0.251:5353"), {
      code: "EHOSTUNREACH",
    })
  );
  const missed: LanService[] = [];
  const first = sender.browse((service) => missed.push(service));
  await refused;
  first.stop();
  expect(missed).toEqual([]);
  expect(warnings).toEqual([expect.stringContaining("EHOSTUNREACH")]);

  net.accept(socket);
  await expect(
    new Promise<LanService>((found) => sender.browse(found))
  ).resolves.toMatchObject({ id: "receiver-id", name: "Ada", port: fakePort });

  receiving.close();
  sender.close();
});

it("stays up when another program holds the mDNS port", async () => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  const warnings: string[] = [];
  const platform = createLanNearbyPlatform({
    log: { warn: (message) => warnings.push(message) },
    socket: air().socket(
      Object.assign(new Error("bind EADDRINUSE"), { code: "EADDRINUSE" })
    ),
  });
  // The socket raises the port it could not take in the tick after the try.
  await new Promise<void>((raised) => process.nextTick(raised));
  expect(warnings).toEqual([expect.stringContaining("EADDRINUSE")]);

  // Each send tries the port again, and the same failure is not reported again.
  platform.advertise(receiver);
  const found: LanService[] = [];
  platform.browse((service) => found.push(service));
  await vi.advanceTimersByTimeAsync(2_000);
  expect(found).toEqual([]);
  expect(warnings).toHaveLength(1);

  platform.close();
});

/** One resource record of a DNS message, as far as this file reads it. */
type DnsRecord = { name: string; type: number; ttl: number; target?: string };
const DNS_A = 1;
const DNS_SRV = 33;
const DNS_AAAA = 28;
const DNS_PTR = 12;
const DNS_ANY = 255;

/** The records of a DNS message (RFC 1035 section 4), compressed names included. */
function dnsRecords(message: Buffer): DnsRecord[] {
  const nameAt = (start: number): { name: string; end: number } => {
    const labels: string[] = [];
    let offset = start;
    let end: number | undefined;
    for (let length = message[offset]!; length; length = message[offset]!) {
      if (length >= 0xc0) {
        end ??= offset + 2;
        offset = message.readUInt16BE(offset) & 0x3fff;
        continue;
      }
      labels.push(message.toString("utf8", offset + 1, offset + 1 + length));
      offset += 1 + length;
    }
    return { name: labels.join("."), end: end ?? offset + 1 };
  };
  let offset = 12;
  for (let question = message.readUInt16BE(4); question > 0; question--)
    offset = nameAt(offset).end + 4;
  const count =
    message.readUInt16BE(6) + message.readUInt16BE(8) + message.readUInt16BE(10);
  const records: DnsRecord[] = [];
  for (let index = 0; index < count; index++) {
    const { name, end } = nameAt(offset);
    const type = message.readUInt16BE(end);
    const ttl = message.readUInt32BE(end + 4);
    const data = end + 10;
    records.push({
      name,
      type,
      ttl,
      ...(type === DNS_SRV ? { target: nameAt(data + 6).name } : {}),
    });
    offset = data + message.readUInt16BE(end + 8);
  }
  return records;
}

/** A DNS query for one name and type. */
function dnsQuery(name: string, type: number) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(1, 4);
  const labels = name
    .split(".")
    .map((label) => Buffer.concat([Buffer.from([label.length]), Buffer.from(label)]));
  const question = Buffer.alloc(5);
  question.writeUInt16BE(type, 1);
  question.writeUInt16BE(1, 3);
  return Buffer.concat([header, ...labels, question]);
}

it("names its addresses for the receiver, never this computer's host name", async () => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  // The name the system's own mDNS responder answers for on this computer.
  const computer = "Ada-MacBook.local";
  vi.spyOn(os, "hostname").mockReturnValue(computer);
  vi.spyOn(os, "networkInterfaces").mockReturnValue({
    en0: [
      {
        address: "192.168.1.20",
        netmask: "255.255.255.0",
        family: "IPv4",
        mac: "00:00:00:00:00:02",
        internal: false,
        cidr: "192.168.1.20/24",
      },
      {
        address: "2001:db8::20",
        netmask: "ffff:ffff:ffff:ffff::",
        family: "IPv6",
        mac: "00:00:00:00:00:02",
        internal: false,
        cidr: "2001:db8::20/64",
        scopeid: 0,
      },
    ],
  });
  const net = air();
  const heard: DnsRecord[] = [];
  const listener = net.socket();
  listener.on("message", (message: Buffer) => heard.push(...dnsRecords(message)));
  /** Settles once a message with a record that `wanted` takes is heard. */
  const hear = (wanted: (record: DnsRecord) => boolean) =>
    new Promise<void>((resolve) => {
      const heardOne = (message: Buffer) => {
        if (!dnsRecords(message).some(wanted)) return;
        listener.off("message", heardOne);
        resolve();
      };
      listener.on("message", heardOne);
    });
  const ask = (name: string, type: number) => {
    const query = dnsQuery(name, type);
    listener.send(query, 0, query.length, 5353, "224.0.0.251", () => undefined);
  };
  const receiving = createLanNearbyPlatform({ socket: net.socket() });
  const sender = createLanNearbyPlatform({ socket: net.socket() });
  const advertised = receiving.advertise(receiver);
  // mDNS probes for the name before it answers for it.
  await vi.advanceTimersByTimeAsync(2_000);
  await expect(
    new Promise<LanService>((resolve) => sender.browse(resolve))
  ).resolves.toMatchObject({
    id: "receiver-id",
    name: "Ada",
    addresses: ["192.168.1.20", "2001:db8::20"],
    port: fakePort,
  });

  // Someone on the network asks for this computer's address.
  const asked = heard.length;
  for (const type of [DNS_A, DNS_AAAA, DNS_ANY]) ask(computer, type);
  // The network delivers in order: once the answer to a later question is
  // heard, any answer to these would have been heard before it.
  const services = "_comma-nearby._tcp.local";
  const answered = hear(({ name, type }) => name === services && type === DNS_PTR);
  ask(services, DNS_PTR);
  await answered;
  expect(
    heard
      .slice(asked)
      .filter(({ name }) => name.toLowerCase() === computer.toLowerCase())
  ).toEqual([]);

  const stopping = heard.length;
  const said = hear(({ ttl }) => ttl === 0);
  advertised.stop();
  await said;
  const goodbye = heard.slice(stopping).filter(({ ttl }) => ttl === 0);
  const host = /^comma-nearby-[a-z0-9-]+\.local$/;
  expect(goodbye.filter(({ type }) => type === DNS_A || type === DNS_AAAA)).toEqual([
    expect.objectContaining({ name: expect.stringMatching(host), type: DNS_A }),
    expect.objectContaining({ name: expect.stringMatching(host), type: DNS_AAAA }),
  ]);

  const addressed = heard.filter(({ type }) => type === DNS_A || type === DNS_AAAA);
  expect(addressed.length).toBeGreaterThan(0);
  for (const record of addressed) expect(record.name).toMatch(host);
  const targets = heard.filter(({ type }) => type === DNS_SRV);
  expect(targets.length).toBeGreaterThan(0);
  for (const record of targets) expect(record.target).toMatch(host);

  receiving.close();
  sender.close();
});

/** A clock whose timers run only when the test says so. */
function manualClock() {
  const timers = new Set<() => void>();
  return {
    now: () => testEpoch,
    setTimer: (_ms: number, run: () => void) => {
      timers.add(run);
      return () => timers.delete(run);
    },
    /** Runs every timer set so far. */
    fire() {
      const due = [...timers];
      timers.clear();
      for (const run of due) run();
    },
  };
}

/**
 * The receiver's computer as mDNS lists it: one address per interface. Each
 * address leads to a stream made in this process, no socket: `refused` fails
 * the connection as a closed port does, `silent` never connects, as an address
 * of a virtual machine bridge, and `receiver` connects to an HTTP server that
 * answers each invite. Every connection started is recorded in order.
 */
function receiverAt(routes: Record<string, "refused" | "silent" | "receiver">) {
  const clock = manualClock();
  const posts: unknown[] = [];
  /** Invites the receiver holds, until the test answers them. */
  const holding: ServerResponse[] = [];
  let held = false;
  let arrived!: () => void;
  const arrival = new Promise<void>((resolve) => {
    arrived = resolve;
  });
  // Never listens: each connection the sender makes is handed to it.
  const server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      posts.push(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      arrived();
      if (held) holding.push(res);
      else res.writeHead(200).end();
    });
  });
  const connected: string[] = [];
  const tries: { count: number; reached: () => void }[] = [];
  const sender = createLanNearbyPlatform({
    clock,
    connect: (address) => {
      connected.push(address);
      for (const wait of tries.filter(({ count }) => count === connected.length))
        wait.reached();
      const [near, far] = duplexPair();
      const route = routes[address];
      if (route === "refused")
        process.nextTick(() =>
          near.emit(
            "error",
            Object.assign(new Error(`connect ECONNREFUSED ${address}`), {
              code: "ECONNREFUSED",
            })
          )
        );
      if (route === "receiver") {
        server.emit("connection", far);
        process.nextTick(() => near.emit("connect"));
      }
      return near;
    },
    interfaces: () => ({
      en0: [
        {
          address: "192.168.1.10",
          netmask: "255.255.255.0",
          family: "IPv4",
          mac: "00:00:00:00:00:01",
          internal: false,
          cidr: "192.168.1.10/24",
        },
      ],
    }),
    socket: air().socket(),
  });
  const service: LanService = {
    id: "receiver-id",
    name: "Ada",
    addresses: Object.keys(routes),
    port: fakePort,
  };
  return {
    clock,
    connected,
    posts,
    /** Settles once the first invite reached the receiver. */
    arrival,
    /** Settles once `count` connections have been started. */
    tried: (count: number) =>
      new Promise<void>((reached) => {
        if (connected.length >= count) reached();
        else tries.push({ count, reached });
      }),
    /** The receiver holds each invite until `answer` is called. */
    hold: () => {
      held = true;
    },
    answer: (status: number) => holding.shift()?.writeHead(status).end(),
    post: () => sender.post(service, { version: 1 }, new AbortController().signal),
    close: () => sender.close(),
  };
}

describe("posting an invite on the local network", () => {
  it("tries the next address when one refuses, and delivers the invite once", async () => {
    const net = receiverAt({ "192.168.1.20": "refused", "192.168.1.30": "receiver" });
    await expect(net.post()).resolves.toBe(200);
    expect(net.connected).toEqual(["192.168.1.20", "192.168.1.30"]);
    expect(net.posts).toEqual([{ version: 1 }]);
    net.close();
  });

  it("moves on from an address that does not connect within the deadline", async () => {
    const net = receiverAt({ "192.168.1.20": "silent", "192.168.1.30": "receiver" });
    const posted = net.post();
    expect(net.connected).toEqual(["192.168.1.20"]);
    // The connect deadline of the first address runs out.
    net.clock.fire();
    await expect(posted).resolves.toBe(200);
    expect(net.connected).toEqual(["192.168.1.20", "192.168.1.30"]);
    expect(net.posts).toEqual([{ version: 1 }]);
    net.close();
  });

  it("tries this computer's subnet first and says why each address failed", async () => {
    const net = receiverAt({
      "fe80::1": "receiver",
      "2001:db8::1": "refused",
      "10.211.55.2": "silent",
      "192.168.1.20": "refused",
    });
    const posted = net.post();
    const failed = expect(posted).rejects.toThrow(LanUnreachableError);
    // The subnet's address is refused; the next one never connects.
    await net.tried(2);
    net.clock.fire();
    await failed;
    const error = (await posted.catch(
      (caught: unknown) => caught
    )) as LanUnreachableError;
    // IPv6 link-local has no zone to reach it by and is not tried.
    expect(error.tried).toEqual([
      { address: "192.168.1.20", code: "ECONNREFUSED" },
      { address: "10.211.55.2", code: "timeout" },
      { address: "2001:db8::1", code: "ECONNREFUSED" },
    ]);
    expect(net.posts).toEqual([]);
    net.close();
  });

  it("waits on an address that connected, however long the answer takes", async () => {
    const net = receiverAt({ "192.168.1.20": "receiver", "192.168.1.30": "receiver" });
    net.hold();
    const posted = net.post();
    await net.arrival;
    // Every timer set so far runs: none of them may send it elsewhere.
    net.clock.fire();
    net.answer(403);
    await expect(posted).resolves.toBe(403);
    expect(net.connected).toEqual(["192.168.1.20"]);
    expect(net.posts).toHaveLength(1);
    net.close();
  });
});
