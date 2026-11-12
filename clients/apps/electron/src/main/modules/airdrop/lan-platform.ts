import type { Socket } from "node:dgram";
import type { EventEmitter } from "node:events";
import { createServer, request } from "node:http";
import { isIPv6 } from "node:net";
import { Bonjour, type ServiceConfig } from "bonjour-service";
import {
  lanNearbyServiceType,
  type LanNearbyPlatform,
  type LanService,
} from "./lan-nearby";

const INVITE_PATH = "/v1/nearby/invite";
const MAX_BODY = 4_096;

/** Node's HTTP server and client and bonjour-service's mDNS (`LanNearby`'s real platform). */
export function createLanNearbyPlatform(
  options: {
    log?: { warn(message: string): void };
    /** The UDP socket mDNS sends and hears on, in place of the multicast one it opens. */
    socket?: Socket;
  } = {}
): LanNearbyPlatform & { close(): void } {
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
    post(service: LanService, body, signal) {
      const payload = JSON.stringify(body);
      return new Promise<number>((resolve, reject) => {
        const req = request(
          {
            host: service.addresses[0],
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
