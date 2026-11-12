import { writeFileSync } from "node:fs";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { NearbyState } from "@comma/native-bridge";
import { testEpoch } from "@comma/test-utils/test-clock";
import { AirDropService } from "../modules/airdrop";
import {
  LanNearby,
  type LanNearbyPlatform,
  type LanService,
} from "../modules/airdrop/lan-nearby";
import { NearbyService } from "../modules/airdrop/nearby";
import { AirDropSender } from "../modules/airdrop/sender";
import {
  fakeAirDropHelper,
  type AirDropHelperRun,
} from "../../test-support/fake-airdrop-helper";

// The helpers are in-process fakes and the clock stands still, so nothing is
// left running between tests and nothing here waits on real time.
const stillClock = { now: () => testEpoch, setTimer: () => () => undefined };
/** What the fake receiver says it listens on; no socket is opened. */
const fakePort = 8771;
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))
  );
});
async function root() {
  const path = await mkdtemp(join(tmpdir(), "comma-nearby-test-"));
  roots.push(path);
  return path;
}
const session = () => {
  const signal = new AbortController().signal;
  return () => ({ signal, assertCurrent() {} });
};
const invite = (token = "t".repeat(43)) =>
  `https://comma.example/#/settings?category=task-requests&invite=${token}`;
/** Waits until a published state passes `test`. */
function watch(states: NearbyState[]) {
  const waiting: { test: (state: NearbyState) => boolean; done: () => void }[] = [];
  return {
    publish(state: NearbyState) {
      states.push(state);
      for (const wait of waiting.slice())
        if (wait.test(state)) {
          waiting.splice(waiting.indexOf(wait), 1);
          wait.done();
        }
    },
    until(test: (state: NearbyState) => boolean) {
      if (states.some(test)) return Promise.resolve();
      return new Promise<void>((done) => waiting.push({ test, done }));
    },
  };
}

/**
 * Two Macs, A and B, each with Main's AirDrop services and its nearby service.
 * The air between them is a pair of fake helpers: A's `find` sees B's Comma
 * receiver and an iPhone, A's `send --url` becomes an offer to B's receiver,
 * and B's answer to it ends A's send, as OpenDropKit's HTTP exchange does.
 */
async function twoMacs(aLan?: LanNearby) {
  const directory = await root();
  const binaryPath = join(directory, "opendropkit");
  await writeFile(binaryPath, "");
  let receiverRun: AirDropHelperRun | undefined;
  const answers = new Map<string, (accept: boolean) => void>();
  const sendArgs: string[][] = [];
  const air = fakeAirDropHelper((run) => {
    run.onStdinEnd(() => run.exit(0));
    if (run.args[0] === "receive") {
      receiverRun = run;
      run.onLine((line) => {
        const { requestId, accept } = JSON.parse(line) as {
          requestId: string;
          accept: boolean;
        };
        answers.get(requestId)?.(accept);
      });
      run.emit({ type: "listening", port: fakePort });
    } else if (run.args[0] === "find") {
      run.emit({ type: "peer", id: "b-mac", name: "Bo’s Comma", model: "Comma" });
      run.emit({ type: "peer", id: "phone", name: "Bo’s iPhone", model: "iPhone" });
      run.emit({ type: "scan_completed", count: 2, truncated: false });
      run.exit(0);
    } else if (run.args[0] === "send") {
      sendArgs.push([...run.args]);
      const requestId = `00000000-0000-4000-8000-${String(sendArgs.length).padStart(12, "0")}`;
      answers.set(requestId, (accept) => {
        if (!accept) {
          run.stderr("Receiver declined");
          run.exit(1);
          return;
        }
        // Accepted, B's receiver saves the link as a file.
        const saved = join(receiverRun!.arg("--directory")!, "comma.example.webloc");
        writeFileSync(saved, "link");
        receiverRun!.emit({ type: "saved_link", path: saved, url: run.arg("--url") });
        receiverRun!.emit({
          type: "transfer_saved",
          requestId,
          paths: [saved],
          complete: true,
        });
        run.emit({ type: "send_completed", peerId: run.arg("--to") });
        run.exit(0);
      });
      receiverRun!.emit({
        type: "approval_requested",
        requestId,
        senderName: run.arg("--name"),
        files: [],
        linkCount: 1,
        links: [run.arg("--url")],
      });
    }
  });

  // A asks.
  const aStates: NearbyState[] = [];
  const a = watch(aStates);
  let aNearby: NearbyService | undefined;
  const sender = new AirDropSender({
    binaryPath,
    clock: stillClock,
    platform: "darwin",
    bindSession: session(),
    spawn: air.spawn,
    onChange: (operation) => aNearby?.onOperation(operation),
  });
  aNearby = new NearbyService({
    lan: aLan,
    publish: a.publish,
    sender,
    senderName: async () => "Ada’s Comma",
  });

  // B answers.
  const bStates: NearbyState[] = [];
  const b = watch(bStates);
  const bNearby = new NearbyService({
    publish: b.publish,
    sender: new AirDropSender({ platform: "darwin", bindSession: session() }),
    senderName: async () => "Bo’s Comma",
  });
  const chatOffers: unknown[] = [];
  const receiver = new AirDropService({
    binaryPath,
    clock: stillClock,
    dataDir: await root(),
    platform: "darwin",
    spawn: air.spawn,
    onOffer: async (offer, signal) => {
      const held = bNearby.offer(offer, signal, "window-1");
      if (held) return held;
      chatOffers.push(offer);
      return undefined;
    },
  });
  const started = await receiver.start();
  return { a, aNearby, air, b, bNearby, chatOffers, receiver, started, sendArgs };
}

describe("Nearby connect over AirDrop", () => {
  it("finds Comma nearby, and the invite waits on the other Mac's answer", async () => {
    const { a, aNearby, b, bNearby, chatOffers, receiver, started, sendArgs } =
      await twoMacs();
    expect(aNearby.state().available).toBe(true);

    aNearby.find();
    await a.until((state) => state.scan === "done");
    // Only Comma's receivers are people to connect with.
    expect(aNearby.state().peers).toEqual([
      { id: "b-mac", name: "Bo’s Comma", via: "airdrop" },
    ]);

    aNearby.ask({ inviteUrl: invite(), peerId: "b-mac" });
    await b.until((state) => state.offers.length === 1);
    const [offer] = bNearby.state().offers;
    expect(offer).toMatchObject({
      invite: "t".repeat(43),
      senderName: "Ada’s Comma",
      surfaceId: "window-1",
    });
    expect(sendArgs[0]).toEqual(
      expect.arrayContaining(["--url", invite(), "--to", "b-mac"])
    );
    // A waits for B's answer.
    expect(aNearby.state().asks).toEqual([{ peerId: "b-mac", status: "asking" }]);

    bNearby.answer({ accept: true, requestId: offer!.requestId });
    await a.until((state) => state.asks[0]?.status === "accepted");
    expect(bNearby.state().offers).toEqual([]);
    // The link is not a chat attachment, and the file the receiver saved for it is gone.
    expect(chatOffers).toEqual([]);
    // `files` waits for the receiver to finish with what it saved.
    await receiver.files(started.receiverId!);
    expect(await readdir(started.directory!)).toEqual([]);
  });

  it("asks again after a decline, and tells the asker it was not accepted", async () => {
    const { a, aNearby, b, bNearby } = await twoMacs();
    aNearby.find();
    await a.until((state) => state.scan === "done");
    aNearby.ask({ inviteUrl: invite(), peerId: "b-mac" });
    await b.until((state) => state.offers.length === 1);
    bNearby.answer({ accept: false, requestId: bNearby.state().offers[0]!.requestId });
    await a.until((state) => state.asks[0]?.status === "unanswered");

    aNearby.ask({ inviteUrl: invite("u".repeat(43)), peerId: "b-mac" });
    expect(aNearby.state().asks).toEqual([{ peerId: "b-mac", status: "asking" }]);
    await b.until((state) => state.offers[0]?.invite === "u".repeat(43));
  });

  it("drops an ask still queued when the session changes", async () => {
    const { a, aNearby, air } = await twoMacs();
    aNearby.find();
    await a.until((state) => state.scan === "done");
    aNearby.ask({ inviteUrl: invite(), peerId: "b-mac" });
    // Another account signs in before the queued send starts.
    aNearby.reset();
    for (let turn = 0; turn < 20; turn++) await Promise.resolve();
    // No send helper started, so the old account's invite never left.
    expect(air.processes.filter((process) => process.args[0] === "send")).toEqual([]);
    expect(aNearby.state().asks).toEqual([]);
  });

  it("leaves other link offers to the chat", async () => {
    const bNearby = new NearbyService({
      publish: () => undefined,
      sender: new AirDropSender({ platform: "darwin", bindSession: session() }),
      senderName: async () => "Bo’s Comma",
    });
    const base = {
      version: 1 as const,
      type: "approval_requested" as const,
      requestId: "11111111-1111-4111-8111-111111111111",
      linkCount: 1,
    };
    const signal = new AbortController().signal;
    expect(
      bNearby.offer(
        { ...base, files: [], links: ["https://example.com/"] },
        signal,
        undefined
      )
    ).toBeUndefined();
    // An invite beside a file is a chat's AirDrop, not a connect request.
    expect(
      bNearby.offer(
        { ...base, files: [{ name: "a.txt", isDirectory: false }], links: [invite()] },
        signal,
        undefined
      )
    ).toBeUndefined();
  });

  it("refuses to ask someone the scan did not find", async () => {
    const { aNearby } = await twoMacs();
    expect(() => aNearby.ask({ inviteUrl: invite(), peerId: "b-mac" })).toThrow(
      "Pick someone the last scan found."
    );
  });
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
 * The local network between two computers: one mDNS registry and direct calls
 * in place of HTTP, so a post reaches the other receiver's handler.
 */
function localNetwork() {
  const services = new Map<string, { service: LanService; answer: LanAnswer }>();
  const browsers = new Set<(service: LanService) => void>();
  const platform = (): LanNearbyPlatform => {
    let answer: LanAnswer | undefined;
    let port = 0;
    return {
      listen: async (handler) => {
        answer = handler;
        port = 40_000 + services.size;
        return { port, close: async () => undefined };
      },
      advertise: ({ airDrop, id, name }) => {
        const service = { airDrop, id, name, addresses: ["192.0.2.1"], port };
        services.set(id, { service, answer: answer! });
        for (const found of browsers) found(service);
        return { stop: () => services.delete(id) };
      },
      browse: (found) => {
        browsers.add(found);
        for (const { service } of services.values()) found(service);
        return { stop: () => browsers.delete(found) };
      },
      post: (service, body, signal) => {
        const target = services.get(service.id);
        if (!target) return Promise.reject(new Error("unreachable"));
        return target.answer(body, signal);
      },
    };
  };
  return { platform };
}
type LanAnswer = (body: unknown, signal: AbortSignal) => Promise<number>;

async function twoComputersOnWifi() {
  const net = localNetwork();
  const clock = manualClock();
  const noAirDrop = new AirDropSender({ platform: "win32", bindSession: session() });
  const aStates: NearbyState[] = [];
  const a = watch(aStates);
  const aLan = new LanNearby({
    clock,
    platform: net.platform(),
    onInvite: async () => false,
  });
  const aNearby = new NearbyService({
    lan: aLan,
    publish: a.publish,
    sender: noAirDrop,
    senderName: async () => "Ada’s Comma",
  });
  // A's own receiver runs too; the list leaves it out.
  await aLan.start(
    async () => "Ada’s Comma",
    () => true
  );

  const bStates: NearbyState[] = [];
  const b = watch(bStates);
  let bNearby!: NearbyService;
  const bLan = new LanNearby({
    clock,
    platform: net.platform(),
    onInvite: (offer, signal) => bNearby.lanInvite(offer, signal),
  });
  bNearby = new NearbyService({
    lan: bLan,
    publish: b.publish,
    sender: noAirDrop,
    senderName: async () => "Bo’s Comma",
    surfaceId: () => "window-1",
  });
  await bLan.start(
    async () => "Bo’s Comma",
    () => true
  );
  return { a, aNearby, b, bNearby, clock };
}

describe("Nearby connect on the same Wi-Fi", () => {
  it("finds Comma on the network and the invite waits on the other computer's answer", async () => {
    const { a, aNearby, b, bNearby, clock } = await twoComputersOnWifi();
    expect(aNearby.state().available).toBe(true);
    aNearby.find();
    expect(aNearby.state().peers).toEqual([
      { id: expect.stringMatching(/^lan:/), name: "Bo’s Comma", via: "wifi" },
    ]);
    clock.fire();
    await a.until((state) => state.scan === "done");

    const [peer] = aNearby.state().peers;
    aNearby.ask({ inviteUrl: invite(), peerId: peer!.id });
    await b.until((state) => state.offers.length === 1);
    expect(bNearby.state().offers[0]).toMatchObject({
      invite: "t".repeat(43),
      senderName: "Ada’s Comma",
      surfaceId: "window-1",
    });
    bNearby.answer({ accept: true, requestId: bNearby.state().offers[0]!.requestId });
    await a.until((state) => state.asks[0]?.status === "accepted");
  });

  it("tells the asker when the other person did not answer in time", async () => {
    const { a, aNearby, b, clock } = await twoComputersOnWifi();
    aNearby.find();
    clock.fire();
    await a.until((state) => state.scan === "done");
    aNearby.ask({ inviteUrl: invite(), peerId: aNearby.state().peers[0]!.id });
    await b.until((state) => state.offers.length === 1);
    // The receiver's wait runs out.
    clock.fire();
    await a.until((state) => state.asks[0]?.status === "unanswered");
    await b.until((state) => state.offers.length === 0);
  });

  it("refuses a post that is not one Comma invite link", async () => {
    const net = localNetwork();
    const held: unknown[] = [];
    const lan = new LanNearby({
      clock: manualClock(),
      platform: net.platform(),
      onInvite: async (offer) => {
        held.push(offer);
        return true;
      },
    });
    await lan.start(
      async () => "Bo’s Comma",
      () => true
    );
    const other = net.platform();
    let service: LanService | undefined;
    other.browse((found) => (service = found)).stop();
    const signal = new AbortController().signal;
    expect(
      await other.post(service!, { version: 1, url: "https://example.com/" }, signal)
    ).toBe(400);
    expect(await other.post(service!, { url: invite() }, signal)).toBe(400);
    expect(held).toEqual([]);
  });

  it("lists a receiver found both ways once, by the AirDrop id it advertises", async () => {
    const net = localNetwork();
    const timers = manualClock();
    const receiver = (name: string, airDrop?: string) =>
      new LanNearby({
        clock: timers,
        platform: net.platform(),
        onInvite: async () => false,
      }).start(
        async () => name,
        () => true,
        () => airDrop
      );
    // Bo's AirDrop receiver is the one A's scan finds (b-mac).
    await receiver("Bo’s Comma", "b-mac");
    // Another Bo, only on the Wi-Fi: the same name is not the same person.
    await receiver("Bo’s Comma");
    // Cy can AirDrop, but this round's AirDrop scan did not reach her Mac.
    await receiver("Cy’s Comma", "c-mac");
    const { a, aNearby, b } = await twoMacs(
      new LanNearby({
        clock: timers,
        platform: net.platform(),
        onInvite: async () => false,
      })
    );
    aNearby.find();
    timers.fire();
    await a.until((state) => state.scan === "done");
    expect(aNearby.state().peers.map(({ name, via }) => [name, via])).toEqual([
      ["Bo’s Comma", "airdrop"],
      ["Bo’s Comma", "wifi"],
      ["Cy’s Comma", "wifi"],
    ]);
    // Cy's row can be asked over the network.
    const cy = aNearby.state().peers.find((peer) => peer.name === "Cy’s Comma")!;
    expect(() => aNearby.ask({ inviteUrl: invite(), peerId: cy.id })).not.toThrow();
    expect(aNearby.state().asks).toEqual([{ peerId: cy.id, status: "asking" }]);
    expect(b).toBeDefined();
  });

  it("sends no Wi-Fi invite once the session changed while the name was read", async () => {
    const net = localNetwork();
    const timers = manualClock();
    const posts: unknown[] = [];
    await new LanNearby({
      clock: timers,
      platform: net.platform(),
      onInvite: async (offer) => {
        posts.push(offer);
        return true;
      },
    }).start(
      async () => "Bo’s Comma",
      () => true
    );
    let nameRead!: (name: string) => void;
    const states: NearbyState[] = [];
    const a = watch(states);
    const aNearby = new NearbyService({
      lan: new LanNearby({
        clock: timers,
        platform: net.platform(),
        onInvite: async () => false,
      }),
      publish: a.publish,
      sender: new AirDropSender({ platform: "win32", bindSession: session() }),
      senderName: () =>
        new Promise((resolve) => {
          nameRead = resolve;
        }),
    });
    aNearby.find();
    timers.fire();
    await a.until((state) => state.scan === "done");
    aNearby.ask({ inviteUrl: invite(), peerId: aNearby.state().peers[0]!.id });
    // Another account signs in while the old one's name is still being read.
    aNearby.reset();
    nameRead("Ada’s Comma");
    for (let turn = 0; turn < 20; turn++) await Promise.resolve();
    expect(posts).toEqual([]);
    expect(aNearby.state().asks).toEqual([]);
  });

  it("stays off when signed out or hidden while the name was being read", async () => {
    const listened: number[] = [];
    const platform = localNetwork().platform();
    const lan = new LanNearby({
      clock: manualClock(),
      platform: {
        ...platform,
        listen: (answer) => (listened.push(1), platform.listen(answer)),
      },
      onInvite: async () => false,
    });
    let shown = true;
    let nameRead!: (name: string) => void;
    let reading!: () => void;
    const askedForName = new Promise<void>((resolve) => {
      reading = resolve;
    });
    const started = lan.start(
      () =>
        new Promise((resolve) => {
          nameRead = resolve;
          reading();
        }),
      () => shown
    );
    // The start is reading the name when the person signs out (or hides Comma nearby).
    await askedForName;
    shown = false;
    void lan.stop();
    nameRead("Old account’s Comma");
    await started;
    await lan.stop();
    expect(listened).toEqual([]);
  });
  it("advertises only the new account's name when the account is replaced mid-read", async () => {
    const advertised: string[] = [];
    const platform = localNetwork().platform();
    const lan = new LanNearby({
      clock: manualClock(),
      platform: {
        ...platform,
        advertise: (service) => (
          advertised.push(service.name),
          platform.advertise(service)
        ),
      },
      onInvite: async () => false,
    });
    // Each start is bound to the session it was asked in, as Main binds it.
    let signedIn = 1;
    const startFor = (name: Promise<string>) => {
      const asked = signedIn;
      return lan.start(
        () => name,
        () => signedIn === asked
      );
    };
    let oldName!: (name: string) => void;
    const first = startFor(
      new Promise((resolve) => {
        oldName = resolve;
      })
    );
    // A's name is still being read when B signs in and asks again.
    signedIn = 2;
    const second = startFor(Promise.resolve("B’s Comma"));
    oldName("A’s Comma");
    await first;
    await second;
    expect(advertised).toEqual(["B’s Comma"]);
  });
});
