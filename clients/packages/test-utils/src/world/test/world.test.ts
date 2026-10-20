import { expect, it } from "vitest";
import { World, type Realm, type RealmReport } from "../world";

// The world gives realms one schedule: a test's record is the same however
// the machine delivers what the realms send each other. Here the realms are
// in memory and a seed decides when each message arrives.

/** Arrival order of the messages on their way, decided by `seed`: the machine's part. */
function machine(seed: number) {
  let state = seed | 0 || 1;
  const random = () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4_294_967_296;
  };
  return {
    /** Resolves after a number of turns of the event loop the seed picks. */
    async travel() {
      for (let turns = Math.floor(random() * 8); turns > 0; turns -= 1)
        await Promise.resolve();
    },
  };
}

type Handler = (realm: MemoryRealm, from: string, label: string) => void;

/** A realm in memory: timers on world time, and messages it holds until the world hands them over. */
class MemoryRealm implements Realm {
  readonly seen: string[] = [];
  #now = 0;
  #nextId = 0;
  #timers: { at: number; order: number; run: () => void }[] = [];
  #sent: { to: string; id: number; label: string }[] = [];
  #arrived = new Map<string, { label: string }>();
  #arrivals = new Map<string, () => void>();
  #handed: { from: string; label: string }[] = [];

  constructor(
    readonly name: string,
    private readonly peers: () => Map<string, MemoryRealm>,
    private readonly travel: () => Promise<void>,
    private readonly onMessage: Handler,
    /** A realm that runs a message when it arrives, not when the world hands it over. */
    private readonly eager = false
  ) {}

  now() {
    return this.#now;
  }

  after(ms: number, run: () => void) {
    this.#timers.push({ at: this.#now + ms, order: (this.#nextId += 1), run });
  }

  send(to: string, label: string) {
    const id = (this.#nextId += 1);
    this.#sent.push({ to, id, label });
    const peer = this.peers().get(to)!;
    void this.travel().then(() => peer.#arrive(this.name, id, label));
  }

  #arrive(from: string, id: number, label: string) {
    if (this.eager) {
      this.onMessage(this, from, label);
      return;
    }
    const key = `${from}:${id}`;
    this.#arrived.set(key, { label });
    this.#arrivals.get(key)?.();
  }

  async deliver(from: string, id: number) {
    if (this.eager) return;
    const key = `${from}:${id}`;
    if (!this.#arrived.has(key))
      await new Promise<void>((resolve) => this.#arrivals.set(key, resolve));
    this.#handed.push({ from, label: this.#arrived.get(key)!.label });
  }

  async settle(now: number): Promise<RealmReport> {
    this.#now = now;
    for (;;) {
      const message = this.#handed.shift();
      if (message) {
        this.onMessage(this, message.from, message.label);
        continue;
      }
      const due = this.#timers
        .filter((timer) => timer.at <= now)
        .toSorted((a, b) => a.at - b.at || a.order - b.order)[0];
      if (!due) break;
      this.#timers.splice(this.#timers.indexOf(due), 1);
      due.run();
    }
    const sent = this.#sent;
    this.#sent = [];
    return {
      nextDue:
        this.#timers.length > 0 ? Math.min(...this.#timers.map((t) => t.at)) : null,
      sent,
    };
  }
}

/**
 * A page asks its core for two things; the core asks the server for each;
 * the server answers the second sooner than the first. The page also has a
 * timer of its own.
 */
async function scenario(seed: number, eagerCore = false) {
  const { travel } = machine(seed);
  const realms = new Map<string, MemoryRealm>();
  const peers = () => realms;
  const page = new MemoryRealm("page", peers, travel, (realm, from, label) => {
    realm.seen.push(`${realm.now()} ${label} from ${from}`);
  });
  const core = new MemoryRealm(
    "core",
    peers,
    travel,
    (realm, from, label) => {
      realm.seen.push(`${realm.now()} ${label} from ${from}`);
      if (from === "page") realm.send("server", `get ${label}`);
      else realm.send("page", `value of ${label}`);
    },
    eagerCore
  );
  const server = new MemoryRealm("server", peers, travel, (realm, _from, label) => {
    realm.after(label === "get tasks" ? 30 : 10, () => realm.send("core", label));
  });
  for (const realm of [page, core, server]) realms.set(realm.name, realm);
  const world = new World([page, core, server]);
  await world.settle();
  page.send("core", "tasks");
  page.send("core", "inbox");
  page.after(20, () => page.seen.push(`${page.now()} timer`));
  world.touched("page");
  await world.until(() => page.seen.length === 3, { what: "the page's three events" });
  return { log: world.log(), page: page.seen, core: core.seen, now: world.now() };
}

it("records the same execution however the machine delivers the realms' messages", async () => {
  const first = await scenario(1);
  expect(first.page).toEqual([
    "10 value of get inbox from core",
    "20 timer",
    "30 value of get tasks from core",
  ]);
  expect(first.now).toBe(30);
  for (let seed = 2; seed <= 40; seed += 1) expect(await scenario(seed)).toEqual(first);
});

it("a realm that runs messages as they arrive records different executions", async () => {
  const cores = new Set<string>();
  for (let seed = 1; seed <= 40; seed += 1) {
    const run = await scenario(seed, true).catch((error: unknown) => ({
      core: [String(error).split("\n")[0]!],
    }));
    cores.add(run.core.join(" | "));
  }
  expect(cores.size).toBeGreaterThan(1);
});

it("fails at once when the condition does not hold and nothing is left to run", async () => {
  const realms = new Map<string, MemoryRealm>();
  const page = new MemoryRealm(
    "page",
    () => realms,
    machine(1).travel,
    () => {}
  );
  realms.set("page", page);
  const world = new World([page]);
  page.after(40, () => page.seen.push("timer"));
  world.touched("page");
  await expect(
    world.until(() => page.seen.length === 2, { what: "two events" })
  ).rejects.toThrow(
    "two events does not hold, and nothing in the world is left to run."
  );
  expect(world.now()).toBe(40);
});

it("advances world time through everything due in it, in order", async () => {
  const realms = new Map<string, MemoryRealm>();
  const travel = machine(3).travel;
  const page = new MemoryRealm(
    "page",
    () => realms,
    travel,
    (realm, _from, label) => {
      realm.seen.push(`${realm.now()} ${label}`);
    }
  );
  const core = new MemoryRealm(
    "core",
    () => realms,
    travel,
    () => {}
  );
  realms.set("page", page);
  realms.set("core", core);
  const world = new World([page, core]);
  core.after(15, () => core.send("page", "late"));
  core.after(5, () => core.send("page", "early"));
  world.touched("core");
  await world.advance(100);
  expect(page.seen).toEqual(["5 early", "15 late"]);
  expect(world.now()).toBe(100);
});

it("hands a realm the messages that follow one another to it together, and it rests once", async () => {
  const realms = new Map<string, MemoryRealm>();
  const travel = machine(5).travel;
  const page = new MemoryRealm(
    "page",
    () => realms,
    travel,
    () => {}
  );
  const core = new MemoryRealm(
    "core",
    () => realms,
    travel,
    (realm, _from, label) => {
      realm.seen.push(label);
    }
  );
  realms.set("page", page);
  realms.set("core", core);
  const world = new World([page, core]);
  page.send("core", "first");
  page.send("core", "second");
  world.touched("page");
  await world.settle();
  expect(core.seen).toEqual(["first", "second"]);
  expect(world.log()).toEqual([
    "0 page rests, sent first to core, second to core",
    "0 core rests",
    "0 core receives first from page",
    "0 core receives second from page",
    "0 core rests",
  ]);
});

it("runs a realm that joins later after the others, and brings a realm to the end of a step", async () => {
  const realms = new Map<string, MemoryRealm>();
  const travel = machine(7).travel;
  const page = new MemoryRealm(
    "page",
    () => realms,
    travel,
    () => {}
  );
  const worker = new MemoryRealm(
    "worker",
    () => realms,
    travel,
    (realm, _from, label) => {
      realm.seen.push(`${realm.now()} ${label}`);
    }
  );
  realms.set("page", page);
  realms.set("worker", worker);
  const world = new World([page]);
  await world.settle();
  world.join(worker);
  page.after(10, () => page.send("worker", "started"));
  world.touched("page");
  await world.advance(30, ["page"]);
  expect(worker.seen).toEqual(["10 started"]);
  expect(page.now()).toBe(30);
  expect(() => world.join(worker)).toThrow("Two realms of a world have the same name.");
});

it("moves a wait that watches a realm past the times at which only other realms run", async () => {
  const realms = new Map<string, MemoryRealm>();
  const travel = machine(9).travel;
  const page = new MemoryRealm(
    "page",
    () => realms,
    travel,
    (realm, _from, label) => {
      realm.seen.push(`${realm.now()} ${label}`);
    }
  );
  const core = new MemoryRealm(
    "core",
    () => realms,
    travel,
    () => {}
  );
  realms.set("page", page);
  realms.set("core", core);
  const world = new World([page, core]);
  // The core's timer at 4 sends nothing; the one at 12 sends the page a message.
  core.after(4, () => {});
  core.after(12, () => core.send("page", "value"));
  page.after(30, () => page.seen.push(`${page.now()} timer`));
  world.touched("core");
  world.touched("page");
  expect(await world.next(100, ["page"], ["page"])).toBe(true);
  expect(world.now()).toBe(12);
  expect(page.seen).toEqual(["12 value"]);
  expect(await world.next(100, ["page"], ["page"])).toBe(true);
  expect(world.now()).toBe(30);
  // Nothing more is due in the page or reaches it.
  core.after(5, () => {});
  world.touched("core");
  expect(await world.next(100, ["page"], ["page"])).toBe(false);
});
