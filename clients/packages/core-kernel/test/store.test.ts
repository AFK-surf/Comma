import { test } from "vitest";
import assert from "node:assert/strict";
import { Kernel, DOING } from "../src/kernel.ts";
import { Runner } from "../src/runtime.ts";
import { CoreError } from "../src/error.ts";
import { TestTime } from "../src/testing.ts";
import { Effect } from "effect";

function setup() {
  const time = new TestTime();
  const sent: [number, unknown][] = [];
  const kernel = new Kernel({
    runner: new Runner(time.clock),
    emit: (client, message) => sent.push([client, JSON.parse(JSON.stringify(message))]),
    nowMs: () => time.now(),
    topics: { rows: {}, count: { of: ["string", "req"] } },
    specOf: (topic) =>
      topic.topic === "rows" ? { fields: { items: { key: ["id"] } } } : null,
  });
  return { time, sent, kernel };
}

test("a computed topic sends its whole value first, then only keyed changes, coalesced", async () => {
  const { time, sent, kernel } = setup();
  const body = "a long body that stays the same ".repeat(4);
  let items = [{ id: "a", n: 1, body }];
  let computed = 0;
  kernel.source("rows", {
    start() {},
    stop() {},
    compute: () => (computed++, { ok: { items } }),
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "rows" }, keyed: true });
  await time.pass(0);
  assert.deepEqual(sent.splice(0), [
    [ui, { id: 1, value: { items: [{ id: "a", n: 1, body }] } }],
  ]);
  items = [{ id: "a", n: 2, body }];
  kernel.store.invalidate({ topic: "rows" });
  items = [{ id: "a", n: 3, body }];
  kernel.store.invalidate({ topic: "rows" });
  await time.pass(60);
  assert.equal(computed, 2, "two invalidations in one window compute once");
  assert.deepEqual(sent.splice(0), [
    [
      ui,
      {
        id: 1,
        delta: [
          { path: ["items"], key: ["id"], patch: "a", ops: [{ path: ["n"], set: 3 }] },
        ],
      },
    ],
  ]);
});

test("a subscriber that comes back within the grace is sent the value as it is now, not as it was last sent", async () => {
  const { time, sent, kernel } = setup();
  let items = [{ id: "a", n: 1 }];
  kernel.source("rows", { start() {}, stop() {}, compute: () => ({ ok: { items } }) });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "rows" }, keyed: true });
  await time.pass(0);
  kernel.receive(ui, { id: 1, unsubscribe: true });
  items = [{ id: "a", n: 2 }];
  kernel.store.invalidateAll((topic) => topic.topic === "rows");
  await time.pass(60);
  sent.splice(0);
  kernel.receive(ui, { id: 2, subscribe: { topic: "rows" }, keyed: true });
  await time.pass(0);
  assert.deepEqual(sent.splice(0), [
    [ui, { id: 2, value: { items: [{ id: "a", n: 2 }] } }],
  ]);
});

test("a source that is not coalesced sends each change as soon as the core yields", async () => {
  const { time, sent, kernel } = setup();
  let n = 0;
  kernel.source("count", {
    coalesce: false,
    start() {},
    stop() {},
    compute: () => ({ ok: n }),
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "count", of: "x" } });
  await time.pass(0);
  sent.splice(0);
  n = 1;
  kernel.store.invalidate({ topic: "count", of: "x" });
  await time.pass(0);
  n = 2;
  kernel.store.invalidate({ topic: "count", of: "x" });
  await time.pass(0);
  assert.equal(sent.length, 2, "two changes, two sends, no coalescing window");
});

test("a topic nobody watches stops a minute after its last subscriber leaves", async () => {
  const { time, kernel } = setup();
  const events: string[] = [];
  kernel.source("count", {
    start: (t) => events.push(`start ${t.of}`),
    stop: (t) => events.push(`stop ${t.of}`),
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "count", of: "x" } });
  kernel.receive(ui, { id: 1, unsubscribe: true });
  await time.pass(59_000, 1000);
  assert.deepEqual(events, ["start x"]);
  await time.pass(2_000, 1000);
  assert.deepEqual(events, ["start x", "stop x"]);
});

test("a source whose work ends with its last view stops after its own short grace", async () => {
  const { time, kernel } = setup();
  const events: string[] = [];
  kernel.source("count", {
    evictAfterMs: 1_000,
    start: (t) => events.push(`start ${t.of}`),
    stop: (t) => events.push(`stop ${t.of}`),
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "count", of: "x" } });
  kernel.receive(ui, { id: 1, unsubscribe: true });
  await time.pass(500);
  kernel.receive(ui, { id: 2, subscribe: { topic: "count", of: "x" } });
  await time.pass(1_000);
  assert.deepEqual(events, ["start x"]);
  kernel.receive(ui, { id: 2, unsubscribe: true });
  await time.pass(1_100, 100);
  assert.deepEqual(events, ["start x", "stop x"]);
});

test("a call that changes something is under way in doing until it answers; a failure stays six seconds", async () => {
  const { time, sent, kernel } = setup();
  kernel.calls({
    "item.save": {
      doing: true,
      run: (_params) =>
        Effect.sleep(1000).pipe(
          Effect.andThen(Effect.fail(new CoreError("conflict", "taken", 409)))
        ),
    },
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: DOING });
  kernel.receive(ui, {
    id: 2,
    call: "item.save",
    params: { item: "a", body: { x: 1 } },
  });
  await time.pass(100);
  const first = sent.splice(0).map(([, m]) => m);
  assert.deepEqual(first.at(-1), {
    id: 1,
    value: {
      doing: [
        {
          call: "item.save",
          params: { item: "a" },
          since: time.now() - 100,
          stage: "running",
        },
      ],
    },
  });
  await time.pass(1000);
  const answer = sent.find(([, m]) => (m as { id: number }).id === 2)?.[1];
  assert.deepEqual(answer, {
    id: 2,
    error: { code: "conflict", message: "taken", status: 409 },
  });
  await time.pass(6_100, 100);
  assert.deepEqual(kernel.store.get(DOING), { doing: [] });
});

test("a cancellable call stops when its UI cancels it, and says so", async () => {
  const { time, sent, kernel } = setup();
  kernel.calls({ "wait.forever": { cancellable: true, run: () => Effect.never } });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 7, call: "wait.forever" });
  kernel.receive(ui, { id: 7, cancel: true });
  await time.pass(10);
  assert.deepEqual(sent, [
    [ui, { id: 7, error: { code: "cancelled", message: "cancelled" } }],
  ]);
});

test("evicting idle topics stops those within their grace and leaves subscribed ones; a new subscriber starts one again", async () => {
  const { time, kernel } = setup();
  const started: string[] = [];
  const stopped: string[] = [];
  kernel.source("count", {
    start: (topic) => started.push(String(topic.of)),
    stop: (topic) => stopped.push(String(topic.of)),
    compute: (topic) => ({ ok: String(topic.of) }),
  });
  const ui = kernel.connect();
  kernel.receive(ui, { id: 1, subscribe: { topic: "count", of: "shown" } });
  kernel.receive(ui, { id: 2, subscribe: { topic: "count", of: "left" } });
  await time.pass(0);
  kernel.receive(ui, { id: 2, unsubscribe: true });
  await time.pass(0);

  kernel.store.evictIdle();
  assert.deepEqual(stopped, ["left"]);
  assert.deepEqual(
    kernel.store.liveTopics().map((topic) => topic.of),
    ["shown"]
  );

  kernel.receive(ui, { id: 3, subscribe: { topic: "count", of: "left" } });
  await time.pass(0);
  assert.deepEqual(started, ["shown", "left", "left"]);
  // The grace the unsubscribe started ends without evicting the topic that is subscribed again.
  await time.pass(60_000);
  assert.deepEqual(stopped, ["left"]);
});
