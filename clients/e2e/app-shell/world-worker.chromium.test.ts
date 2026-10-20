import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { pageWorld } from "./support/world";

// A page and its worker are two realms: each has timers of its own, and what
// one posts the other arrives when the browser delivers it. As realms of one
// world they run one at a time, on the world's time, and each message is
// handed over in the order it was sent.
useFixture(
  fixtureMount(new URL("./fixtures/world-worker/src/main.ts", import.meta.url)),
  // The warm-up's page starts the worker once: the tests' pages start it from
  // memory.
  { world: true, warmUp: ["http://fixture.test/"] }
);
const fixtureUrl = "http://fixture.test/";

test("a page and its worker run on one schedule", async ({ page }) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  const start = world.now();
  await page.evaluate(() => window.worldFixture!.start());
  world.touched("page");
  const lines = () => page.evaluate(() => [...window.worldFixture!.log]);
  await world.until(async () => (await lines()).length === 3, {
    what: "the page's three events",
  });
  // The worker answers "inbox" 10 ms after it was asked and "tasks" 30 ms
  // after; the page's own timer falls between them.
  expect(await lines()).toEqual([
    "10 answer to inbox",
    "20 timer",
    "30 answer to tasks",
  ]);
  expect(world.now() - start).toBe(30);
  expect(world.log().filter((line) => line.includes("receives"))).toEqual([
    `${start} worker 1 receives tasks from page`,
    `${start} worker 1 receives inbox from page`,
    `${start + 10} page receives answer to inbox from worker 1`,
    `${start + 30} page receives answer to tasks from worker 1`,
  ]);
});

test("a wait that nothing in the world can end fails at once", async ({ page }) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  await page.evaluate(() => window.worldFixture!.start());
  world.touched("page");
  await expect(
    world.until(
      async () => (await page.evaluate(() => window.worldFixture!.log.length)) === 4,
      { what: "a fourth event" }
    )
  ).rejects.toThrow(
    "a fourth event does not hold, and nothing in the world is left to run."
  );
});
