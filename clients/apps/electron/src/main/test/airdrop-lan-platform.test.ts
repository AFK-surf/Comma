import type { Socket } from "node:dgram";
import { EventEmitter } from "node:events";
import { afterEach, expect, it, vi } from "vitest";
import type { LanService } from "../modules/airdrop/lan-nearby";
import { createLanNearbyPlatform } from "../modules/airdrop/lan-platform";

afterEach(() => {
  vi.useRealTimers();
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
