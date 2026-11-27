import type { Socket } from "node:dgram";
import type { EventEmitter } from "node:events";
import { createServer, request } from "node:http";
import { connect as netConnect, isIPv4, isIPv6 } from "node:net";
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import type { Duplex } from "node:stream";
import { Bonjour, type ServiceConfig } from "bonjour-service";
import { realMainClock, type MainClock } from "../../clock";
import {
  LanUnreachableError,
  lanNearbyServiceType,
  type LanNearbyPlatform,
  type LanService,
} from "./lan-nearby";

const INVITE_PATH = "/v1/nearby/invite";
const MAX_BODY = 4_096;
/**
 * How long one address may take to connect before the next is tried. Nothing
 * has been sent to an address that has not connected, so trying the next one
 * cannot deliver the invite twice.
 */
const CONNECT_MS = 3_000;

type Interfaces = NodeJS.Dict<NetworkInterfaceInfo[]>;

const ipv4Number = (address: string) =>
  address.split(".").reduce((value, part) => ((value << 8) | Number(part)) >>> 0, 0);

/**
 * The order to try a receiver's addresses in. mDNS gives one for every
 * interface of that computer (virtual machine bridges, a second network card),
 * and many are not reachable from here: IPv4 addresses on a subnet of one of
 * this computer's own interfaces first, then other IPv4, then IPv6. IPv6
 * link-local addresses are left out, since mDNS gives no zone to reach them by.
 */
export function lanAddressOrder(addresses: readonly string[], interfaces: Interfaces) {
  const own = Object.values(interfaces)
    .flatMap((list) => list ?? [])
    .filter((entry) => entry.family === "IPv4");
  const near = (address: string) =>
    own.some((entry) => {
      const mask = ipv4Number(entry.netmask);
      return (
        (ipv4Number(address) & mask) >>> 0 === (ipv4Number(entry.address) & mask) >>> 0
      );
    });
  const v4 = addresses.filter((address) => isIPv4(address));
  const v6 = addresses.filter(
    (address) => isIPv6(address) && !/^fe[89ab]/i.test(address)
  );
  return [
    ...new Set([...v4.filter(near), ...v4.filter((address) => !near(address)), ...v6]),
  ];
}

/**
 * The mDNS host name a receiver's address records go by: one of Comma's own,
 * made from the receiver's id. bonjour-service otherwise uses this computer's
 * own name, which the system's mDNS responder holds: two answerers for one name
 * make macOS say the name is in use on the network and rename the computer.
 */
export function lanNearbyHost(id: string) {
  const prefix = "comma-nearby";
  const label = id
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .slice(0, 63 - prefix.length - 1)
    .replace(/^-+|-+$/g, "");
  return `${label ? `${prefix}-${label}` : prefix}.local`;
}

/** Node's HTTP server and client and bonjour-service's mDNS (`LanNearby`'s real platform). */
export function createLanNearbyPlatform(
  options: {
    clock?: MainClock;
    /**
     * Opens a TCP connection to an address (`net.connect` by default): the
     * stream emits `connect` once connected, or `error`.
     */
    connect?: (address: string, port: number) => Duplex;
    /** This computer's network interfaces (`os.networkInterfaces` by default). */
    interfaces?: () => Interfaces;
    log?: { warn(message: string): void };
    /** The UDP socket mDNS sends and hears on, in place of the multicast one it opens. */
    socket?: Socket;
  } = {}
): LanNearbyPlatform & { close(): void } {
  const clock = options.clock ?? realMainClock;
  const connect =
    options.connect ??
    ((address: string, port: number) => netConnect({ host: address, port }));
  const interfaces = options.interfaces ?? networkInterfaces;
  /** One address after another until one connects; `LanUnreachableError` when none does. */
  const connectFirst = async (service: LanService, signal: AbortSignal) => {
    const tried: { address: string; code: string }[] = [];
    for (const address of lanAddressOrder(service.addresses, interfaces())) {
      const outcome = await new Promise<Duplex | string>((resolve) => {
        let settled = false;
        const socket = connect(address, service.port);
        const done = (result: Duplex | string) => {
          if (settled) return;
          settled = true;
          cancel();
          signal.removeEventListener("abort", aborted);
          if (typeof result === "string") socket.destroy();
          resolve(result);
        };
        const aborted = () => done("aborted");
        const cancel = clock.setTimer(CONNECT_MS, () => done("timeout"));
        socket.once("connect", () => done(socket));
        // Stays on: an error after the connection is the request's to report.
        socket.on("error", (error: NodeJS.ErrnoException) =>
          done(error.code ?? error.message)
        );
        if (signal.aborted) aborted();
        else signal.addEventListener("abort", aborted, { once: true });
      });
      if (typeof outcome !== "string") return { address, socket: outcome };
      tried.push({ address, code: outcome });
      if (outcome === "aborted") break;
    }
    throw new LanUnreachableError(tried);
  };
  const mdns: Partial<ServiceConfig> & { socket?: Socket } = options.socket
    ? { socket: options.socket }
    : {};
  // Each kind of mDNS failure is reported once for the life of Main: the same
  // one comes back with every query and send while it lasts, and mDNS gives no
  // sign of a send that went through to tell when it has ended.
  const reported = new Set<string>();
  const report = (error: NodeJS.ErrnoException) => {
    const kind = error.code ?? error.message;
    if (reported.has(kind)) return;
    reported.add(kind);
    options.log?.warn(`Nearby local network mDNS failed: ${error.message}`);
  };
  // The network may not take an answer to an mDNS query: no route to the
  // multicast group, as when the computer changes networks. Left to itself,
  // bonjour-service throws that from the socket's callback, an uncaught
  // exception in Main. Whoever asked asks again.
  const bonjour = new Bonjour(mdns, report);
  // A port that another program holds for itself is an "error" event of
  // multicast-dns, at the start and again with each send, and an uncaught
  // exception with no listener. bonjour-service keeps that emitter to itself.
  (bonjour as unknown as { server: { mdns: EventEmitter } }).server.mdns.on(
    "error",
    report
  );
  return {
    async listen(answer) {
      const server = createServer((req, res) => {
        if (req.method !== "POST" || req.url !== INVITE_PATH) {
          res.writeHead(404).end();
          return;
        }
        const controller = new AbortController();
        res.once("close", () => controller.abort());
        let size = 0;
        const chunks: Buffer[] = [];
        req.on("data", (chunk: Buffer) => {
          size += chunk.length;
          if (size > MAX_BODY) {
            res.writeHead(413).end();
            req.destroy();
            return;
          }
          chunks.push(chunk);
        });
        req.on("end", () => {
          if (res.writableEnded) return;
          let body: unknown;
          try {
            body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          } catch {
            res.writeHead(400).end();
            return;
          }
          answer(body, controller.signal).then(
            (status) => res.writeHead(status).end(),
            () => res.writeHead(500).end()
          );
        });
      });
      // A held invite waits for the person; Node's own request timeouts must not end it first.
      server.requestTimeout = 0;
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, () => resolve());
      });
      const address = server.address();
      if (!address || typeof address === "string")
        throw new Error("No port to listen on.");
      return {
        port: address.port,
        close: () =>
          new Promise<void>((resolve) => {
            server.closeAllConnections();
            server.close(() => resolve());
          }),
      };
    },
    advertise({ airDrop, id, name, port }) {
      const service = bonjour.publish({
        name,
        type: lanNearbyServiceType,
        port,
        host: lanNearbyHost(id),
        txt: { v: "1", id, ...(airDrop ? { airdrop: airDrop } : {}) },
        // Two people may share an AirDrop name; mDNS renames the later one.
        probe: true,
      });
      return { stop: () => service.stop?.() };
    },
    browse(found) {
      const browser = bonjour.find({ type: lanNearbyServiceType }, (service) => {
        const id = typeof service.txt?.id === "string" ? service.txt.id : "";
        if (!id) return;
        const addresses = (service.addresses ?? []).toSorted(
          (a, b) => Number(isIPv6(a)) - Number(isIPv6(b))
        );
        found({
          id,
          name: service.name,
          airDrop:
            typeof service.txt?.airdrop === "string" ? service.txt.airdrop : undefined,
          addresses,
          port: service.port,
        });
      });
      return { stop: () => browser.stop() };
    },
    async post(service: LanService, body, signal) {
      const payload = JSON.stringify(body);
      // Once an address took the connection it is the one: the request may
      // reach the receiver from here on, so it is never sent to another.
      const { address, socket } = await connectFirst(service, signal);
      return new Promise<number>((resolve, reject) => {
        const req = request(
          {
            createConnection: () => socket,
            host: address,
            port: service.port,
            path: INVITE_PATH,
            method: "POST",
            headers: {
              "content-type": "application/json",
              "content-length": Buffer.byteLength(payload),
            },
            signal,
          },
          (res) => {
            res.resume();
            resolve(res.statusCode ?? 0);
          }
        );
        req.once("error", reject);
        req.end(payload);
      });
    },
    close: () => bonjour.destroy(),
  };
}
