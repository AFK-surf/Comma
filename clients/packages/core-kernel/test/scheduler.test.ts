import { test } from "vitest";
import assert from "node:assert/strict";
import { Effect } from "effect";
import { Runner } from "../src/runtime.ts";
import { Priority, Scheduler } from "../src/scheduler.ts";
import { TestTime } from "../src/testing.ts";

test("a lane runs its most urgent tasks first, a few at a time, one run per key", async () => {
  const time = new TestTime();
  const runner = new Runner(time.clock);
  const scheduler = new Scheduler(runner, runner.root, () => 1);
  const ran: string[] = [];
  const task = (name: string) =>
    Effect.sync(() => ran.push(name)).pipe(Effect.andThen(Effect.sleep(100)));
  scheduler.enqueue("api", "a", Priority.background, task("a"));
  scheduler.enqueue("api", "b", Priority.background, task("b"));
  scheduler.enqueue("api", "c", Priority.shown, task("c"));
  scheduler.enqueue("api", "b", Priority.asked, task("b again"));
  await time.pass(400);
  assert.deepEqual(ran, ["a", "b", "c"]);
});

test("a task is asked for when the asking effect runs, not when it is made", async () => {
  const time = new TestTime();
  const runner = new Runner(time.clock);
  const scheduler = new Scheduler(runner, runner.root);
  let runs = 0;
  const later = Effect.sleep(1_000).pipe(
    Effect.andThen(
      scheduler.ask(
        "api",
        "a",
        Priority.background,
        Effect.sync(() => void runs++)
      )
    )
  );
  runner.fork(later);
  await time.pass(500);
  assert.equal(runs, 0);
  await time.pass(600);
  assert.equal(runs, 1);
});
