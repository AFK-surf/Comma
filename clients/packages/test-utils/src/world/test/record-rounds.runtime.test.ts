import { afterEach, expect, it } from "vitest";
import { createRealm } from "../../../../../e2e/ui-runtime/realm";
import {
  absentRealm,
  exchangeLog,
  recordedLine,
  recordedPeer,
  type Exchanged,
} from "../../../../../e2e/ui-runtime/scripted-peer";
import { createTestUiRuntime } from "../../../../ui/src/runtime/test/testing";
import { World, type Realm, type SentMessage } from "../world";

// A record of a page and its core replays on the code that made it: the
// view alone meets each message of the record in the round and at the world
// time it met it in the whole world. Here the page is a realm on the test UI
// runtime with a small view whose sends depend on both; the core and the
// server are in memory.

let uninstall: (() => void) | undefined;
afterEach(() => {
  uninstall?.();
  uninstall = undefined;
});

/** A realm in memory: `on` runs for each message handed to it; its timers run on world time. */
function memoryRealm(
  name: string,
  on: (realm: MemoryRealm, from: string, id: number) => void
) {
  let now = 0;
  let sent: SentMessage[] = [];
  const ids = new Map<string, number>();
  const handed: { from: string; id: number }[] = [];
  const timers: { at: number; work: () => void }[] = [];
  const realm = {
    name,
    after(ms: number, work: () => void) {
      timers.push({ at: now + ms, work });
    },
    send(to: string, label: string) {
      const id = (ids.get(to) ?? 0) + 1;
      ids.set(to, id);
      sent.push({ to, id, label });
    },
    async deliver(from: string, id: number) {
      handed.push({ from, id });
    },
    async settle(at: number) {
      now = at;
      for (const message of handed.splice(0)) on(realm, message.from, message.id);
      for (const timer of timers.filter((each) => each.at <= now)) {
        timers.splice(timers.indexOf(timer), 1);
        timer.work();
      }
      const report = {
        nextDue: timers.length > 0 ? Math.min(...timers.map((each) => each.at)) : null,
        sent,
      };
      sent = [];
      return report;
    },
  };
  return realm;
}
type MemoryRealm = ReturnType<typeof memoryRealm>;

/** What the core does when the page's first message reaches it. */
type Core = (core: MemoryRealm & { say(data: string): void }) => void;
type Steps = (world: World, input: (what: string) => void) => Promise<void>;

/**
 * Runs `steps` on a page whose view is `view`: with `core` and a server, the
 * whole world, or with `record` played to it, the view alone. Returns what
 * the page noted.
 */
async function run(
  {
    core,
    record,
    view = rendering,
  }: { core?: Core; record?: Exchanged[]; view?: View },
  steps: Steps
) {
  const runtime = createTestUiRuntime({ seed: 1 });
  uninstall?.();
  uninstall = runtime.install();
  const realm = createRealm(runtime, {
    advance: (ms) => runtime.advance(ms),
    rest: () => runtime.flush(),
  });
  const log = exchangeLog(() => runtime.elapsed());
  // The page's line to its worker: a record's, or one in memory.
  const played = record ? recordedLine() : undefined;
  let arrive: ((event: Event) => void) | undefined;
  const endpoint = (played?.endpoint ?? {
    addEventListener(_type: string, listener: (event: Event) => void) {
      arrive = listener;
    },
    postMessage() {},
    onmessage: null,
  }) as unknown as Parameters<typeof realm.route>[1];
  realm.route("worker 1", endpoint, () => {}, { ran: log.ran });
  log.sends(endpoint);
  const peer =
    record && played
      ? recordedPeer(record, { exchanged: () => log.entries, inject: played.inject })
      : undefined;
  const page: Realm = {
    name: "page",
    deliver: realm.control.deliver,
    async settle(now) {
      const report = await realm.control.settle(now);
      log.rested();
      peer?.caughtUp();
      return report;
    },
  };
  const world = new World(
    peer
      ? [page, peer]
      : [
          page,
          absentRealm(
            memoryRealm("server", () => {}),
            log.due
          ),
          absentRealm(
            memoryRealm("worker 1", (worker, _from, id) => {
              if (id > 1) return;
              core!({
                ...worker,
                say(data) {
                  arrive!(new MessageEvent("message", { data }));
                  worker.send("page", data);
                },
              });
            }),
            log.due
          ),
        ]
  );
  const input = view(runtime, {
    hears: (listener) =>
      endpoint.addEventListener("message", (event) =>
        listener((event as MessageEvent<string>).data)
      ),
    // A worker's line has no target origin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    sends: (data) => endpoint.postMessage(data),
  });
  await steps(world, (what) => {
    input(what);
    world.touched("page");
  });
  if (peer) expect(peer.played()).toBe(record!.length);
  return log.entries;
}

/** A page's view on its line to the core; returns how the test's input reaches it. */
type View = (
  runtime: ReturnType<typeof createTestUiRuntime>,
  core: { hears(listener: (said: string) => void): void; sends(data: string): void }
) => (what: string) => void;

/**
 * A view as React makes one: a message changes what the view knows at once,
 * and what it shows in a task of its own, behind the messages already handed
 * over. It answers a question with what it shows then. The test's input
 * reaches it in its next round.
 */
const rendering: View = (runtime, core) => {
  const known: string[] = [];
  let shows = "nothing";
  core.hears((said) => {
    known.push(said);
    runtime.task.post(() => {
      shows = known.join(" ");
    });
    if (said.endsWith("?")) core.sends(`${said} over ${shows}`);
  });
  return (what) =>
    runtime.task.post(() => core.sends(`${what} at ${runtime.elapsed()} ms`));
};

/** A view that shows a message as it arrives. */
const eager: View = (runtime, core) => {
  const known: string[] = [];
  core.hears((said) => {
    core.sends(`${said} over ${known.join(" ") || "nothing"}`);
    known.push(said);
  });
  return (what) =>
    runtime.task.post(() => core.sends(`${what} at ${runtime.elapsed()} ms`));
};

const start: Steps = async (world, input) => {
  input("start");
  await world.settle();
};

it("hands the view the messages of one round together, though the view sent between them", async () => {
  const record = await run(
    {
      core(core) {
        core.say("tasks?");
        core.say("profile?");
      },
    },
    start
  );
  expect(record).toEqual([
    { at: 0, dir: "out", data: "start at 0 ms" },
    { at: 0, dir: "rest" },
    { at: 0, dir: "in", data: "tasks?" },
    { at: 0, dir: "out", data: "tasks? over nothing" },
    { at: 0, dir: "in", data: "profile?" },
    { at: 0, dir: "out", data: "profile? over nothing" },
    { at: 0, dir: "rest" },
  ]);
  expect(await run({ record }, start)).toEqual(record);
});

it("hands the view the messages of two rounds apart, though the view sent nothing between them", async () => {
  const record = await run(
    {
      // The core asks the server between the two: the page rests between them.
      core(core) {
        core.say("tasks");
        core.send("server", "get profile");
        core.say("profile?");
      },
    },
    start
  );
  expect(record).toEqual([
    { at: 0, dir: "out", data: "start at 0 ms" },
    { at: 0, dir: "rest" },
    { at: 0, dir: "in", data: "tasks" },
    { at: 0, dir: "rest" },
    { at: 0, dir: "in", data: "profile?" },
    { at: 0, dir: "out", data: "profile? over tasks" },
    { at: 0, dir: "rest" },
  ]);
  expect(await run({ record }, start)).toEqual(record);
});

it("moves the world's time where it moved for the core alone", async () => {
  // A wait ends where nothing more is due: at the core's timer, which says
  // nothing to the page. The frame the test then waits, and its next input,
  // fall after that time.
  const steps: Steps = async (world, input) => {
    await start(world, input);
    expect(await world.next(60, ["page"], ["page"])).toBe(false);
    await world.advance(10, ["page"]);
    input("click");
    await world.settle();
  };
  const record = await run(
    { core: (core) => core.after(30, () => core.send("server", "sync")) },
    steps
  );
  expect(record).toEqual([
    { at: 0, dir: "out", data: "start at 0 ms" },
    { at: 0, dir: "rest" },
    { at: 30, dir: "due" },
    { at: 40, dir: "out", data: "click at 40 ms" },
    { at: 40, dir: "rest" },
  ]);
  // The page notes what it did; where the world's time moved is the world's note.
  expect(await run({ record }, steps)).toEqual(
    record.filter((entry) => entry.dir !== "due")
  );
});

it("fails at the first entry where the view parts from its record", async () => {
  const record = await run(
    {
      core(core) {
        core.say("tasks?");
        core.say("profile?");
      },
    },
    start
  );
  await expect(run({ record, view: eager }, start)).rejects.toThrow(
    'The view sent "profile? over tasks?" at 0 ms, where the record has out "profile? over nothing" at 0 ms (entry 6 of 7).'
  );
  // A record that does not say where the page rested is not played by guess.
  await expect(
    run({ record: record.filter((entry) => entry.dir !== "rest") }, start)
  ).rejects.toThrow("The record does not say where the page rested");
});
