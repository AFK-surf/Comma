import { World, type Realm } from "@comma/test-utils/world/world";
import { afterEach, beforeEach } from "vitest";
import { commands } from "vitest/browser";
import {
  absentRealm,
  recordedPeer,
  type Exchanged,
} from "../../ui-runtime/scripted-peer";
import { runningClock, setClockWorld, testPage } from "./virtual-time";

/**
 * A Node process that is a realm of the test's world
 * (../../ui-runtime/node-realm.ts): a server that answers the requests the
 * page and its workers make to its origin.
 */
export type NodeRealm<Info> = Realm & {
  /** What the realm's entry said of itself. */
  readonly info: Info;
  /** Where its server listens. */
  readonly origin: string;
  /** The proof's perturbation, as the realm's process was started with it. */
  readonly delayMs: number;
  /** Calls `name` of the realm's entry, as the realm's code. */
  call(name: string, ...args: unknown[]): Promise<unknown>;
  /** The page whose requests it answered closed: it drops what they left. */
  forget(): Promise<void>;
};

// The pages the test opened: each page's requests have names of their own.
let pageEpoch = 0;

// The world of the running test's page.
let world: World | undefined;
// The record the pages opened from now on play instead of running a worker.
let replay: readonly Exchanged[] | undefined;

// The steps the test took on other realms before its page opened.
let before: Exchanged[] = [];

/** What the running test's page and its worker exchanged so far, after the steps the test took before the page opened. */
export const exchanged = (): Exchanged[] => [
  ...before,
  ...structuredClone(testPage().world!().exchanged()),
];

/**
 * The pages the test opens from now on run alone: no worker and no server,
 * their worker's part played from `record` (../../ui-runtime/scripted-peer.ts).
 * Undefined ends it.
 */
export function viewAlone(record: readonly Exchanged[] | undefined) {
  replay = record;
}

/** A new test begins: the test before it left no world and no record. */
export function forgetWorld() {
  world = undefined;
  replay = undefined;
  core = undefined;
  before = [];
}

/** Whether the running test's page has opened as a realm of a world. */
export const inWorld = () => world !== undefined;

/** How far the running page played its record: the next entry, counted from 0. */
export const played = () => core?.played();

let core: ReturnType<typeof recordedPeer> | undefined;

/** A view alone: the test's step `name` on a realm that is not there is the record's. */
export function recordedStep(name: string) {
  if (!core || !world) throw new Error("No page of this test runs a record.");
  const result = core.step(name);
  world.touched("worker 1");
  return result;
}

/**
 * Each test of the spec has a Node realm of its own, started from `entry` (a
 * path in clients/, whose default export starts the realm and says its
 * server's `origin`) with `start`, or with what `start` gives for the test's
 * name: a test's realm is one of its inputs. Returns the running test's.
 */
export function useNodeRealm<Info extends { origin: string }>(
  name: string,
  entry: string,
  start?: unknown,
  /** A test this is true of has no realm: its page runs alone (`viewAlone`). */
  without: () => boolean = () => false
) {
  let realm: NodeRealm<Info> | undefined;
  let stop: (() => Promise<void>) | undefined;
  beforeEach(async (context) => {
    if (without()) return;
    const input =
      typeof start === "function"
        ? (start as (test: string) => unknown)(context.task.name)
        : start;
    const started = await commands.nodeRealmStart(entry, {
      name,
      seed: 1,
      start: input,
    });
    stop = async () => {
      // What the realm did after the world last ran it fails the test too.
      const outside = (await commands.nodeRealmCall(started.id, {
        op: "close",
      })) as string[];
      await commands.nodeRealmStop(started.id);
      if (outside.length > 0) throw new Error(outside.join("\n"));
    };
    const info = started.info as Info;
    realm = {
      name,
      info,
      origin: info.origin,
      delayMs: started.delayMs,
      settle: (now) =>
        commands.nodeRealmCall(started.id, { op: "settle", now }) as ReturnType<
          Realm["settle"]
        >,
      deliver: async (from, id, detail) => {
        await commands.nodeRealmCall(started.id, { op: "deliver", from, id, detail });
      },
      forget: async () => {
        await commands.nodeRealmCall(started.id, { op: "forget" });
      },
      async call(call, ...args) {
        // A view alone has no server: the call is the record's step, and its
        // result the one the server gave then.
        if (replay && world) return recordedStep(`${name}.${call}`);
        const result = await commands.nodeRealmCall(started.id, {
          op: "call",
          name: call,
          args,
        });
        // What the call started is the realm's to run; the page notes the
        // step among what it exchanged with its worker.
        if (runningClock() && world) {
          world.touched(name);
          testPage().world!().step(`${name}.${call}`, args, result);
        } else
          before.push({
            at: 0,
            dir: "step",
            before: true,
            data: { name: `${name}.${call}`, args, result },
          });
        return result;
      },
    };
  });
  afterEach(async () => {
    realm = undefined;
    await stop?.();
    stop = undefined;
  });
  return () => {
    if (!realm) throw new Error(`The realm ${name} runs only during a test.`);
    return realm;
  };
}

/**
 * Makes the page that just opened a realm of a new world, before its fixture
 * mounts (`useFixture(..., { world })`): the page, then `servers`, then the
 * workers the page starts, as it starts them. From now on the test clock
 * moves the world: a step of page time is a step of every realm.
 */
export async function openPageWorld(servers: readonly NodeRealm<unknown>[]) {
  const page = testPage();
  core = undefined;
  const entered = page.world?.(replay ? { replay: true } : {});
  if (!entered) throw new Error("Only a page on the UI runtime is a realm of a world.");
  // A view alone asks no server: every answer it had is in its record.
  if (replay) servers = [];
  pageEpoch += 1;
  for (const server of servers) {
    // What a page before this one left with the server is gone with it.
    await server.forget();
    await entered.http({
      peer: server.name,
      origin: server.origin,
      delayMs: server.delayMs,
      epoch: pageEpoch,
    });
  }
  const joined = new Set<string>();
  // The realms the page started (its workers, its frames, and theirs) join
  // the world once a realm that started one rests, before the world reads
  // what it sent them.
  const joinNew = () => {
    for (const name of entered.workers()) {
      if (joined.has(name)) continue;
      joined.add(name);
      const realm = entered.worker(name);
      const started: Realm = {
        name,
        deliver: realm.deliver,
        async settle(now) {
          const report = await realm.settle(now);
          joinNew();
          return report;
        },
      };
      // A view alone has its frames, and no worker.
      opened.join(frameName.test(name) ? started : absentRealm(started, entered.due));
    }
  };
  // A frame of the page receives input of its own and shows frames as the
  // page does: each step touches it and brings it.
  const frameName = /^frame \d+$/;
  const frames = () => [...joined].filter((name) => frameName.test(name));
  const opened = new World(
    [
      {
        name: "page",
        deliver: entered.page.deliver,
        async settle(now) {
          const report = await entered.page.settle(now);
          joinNew();
          // A view alone did in this round what the record has, or fails here.
          core?.caughtUp();
          return report;
        },
      },
      ...servers.map((server) => absentRealm(server, entered.due)),
      ...(replay ? [(core = recordedPeer(replay, entered))] : []),
    ],
    { now: page.elapsed() }
  );
  world = opened;
  // Input that reached a frame runs there first: what the frame posts its
  // page reaches the page before the page's next frame, as a message task
  // comes before rendering.
  const inputFirst = async () => {
    if (frames().length > 0) {
      for (const frame of frames()) opened.touched(frame);
      await opened.settle();
    }
    // What the test did to the page since the last step is the page's to run.
    opened.touched("page");
  };
  setClockWorld(
    async (ms) => {
      await inputFirst();
      await opened.advance(ms, ["page", ...frames()]);
    },
    async (limit) => {
      await inputFirst();
      // The test looks at the page and its frames.
      const seen = ["page", ...frames()];
      return opened.next(limit, seen, seen);
    }
  );
}

/** The fixture mounted on page time alone: the world's time comes up to the page's. */
export async function pageMountedInWorld() {
  if (!world) return;
  world.touched("page");
  await world.advance(Math.max(0, testPage().elapsed() - world.now()), ["page"]);
}

/** The world of the running test's page (`useFixture(..., { world })`). */
export function pageWorld(): World {
  if (!world || !runningClock())
    throw new Error("The running test's page is no realm of a world.");
  return world;
}
