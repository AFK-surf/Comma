import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { stepUntilSettled } from "./support/virtual-time";

// The test page's random numbers come from the test's seed (./support/random).
useFixture(
  fixtureMount(
    new URL("./fixtures/page-random/src/main.ts", import.meta.url),
    `<iframe id="frame" srcdoc="<p>nested</p>"></iframe>`
  ),
  // The warm-up's page starts the worker once: the tests' pages start it from
  // memory.
  {
    // What this file checks is the page on fake timers (./support/child) and
    // its seeded sources.
    runtime: false,
    warmUp: [
      async (page) => {
        await page.goto("http://fixture.test/");
        await stepUntilSettled(page.evaluate(() => window.workerDraws!()));
      },
    ],
  }
);
const fixtureUrl = "http://fixture.test/";

// Draws in the test page, whose sources the test's seed drives: what this file
// checks.
const draws = () => {
  const frame = (document.getElementById("frame") as HTMLIFrameElement)
    .contentWindow as unknown as typeof globalThis;
  return {
    // ast-grep-ignore: ts-test-random
    random: [Math.random(), Math.random()],
    // ast-grep-ignore: ts-test-random
    values: Array.from(crypto.getRandomValues(new Uint32Array(2))),
    // ast-grep-ignore: ts-test-random
    uuid: crypto.randomUUID(),
    // ast-grep-ignore: ts-test-random
    frame: frame.Math.random(),
  };
};

test("a reopened page draws the same random numbers, in its frames too", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const first = await page.evaluate(draws);
  await page.goto(fixtureUrl);
  expect(await page.evaluate(draws)).toEqual(first);
  expect(first.uuid).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  );
});

test("a worker of the page draws the same random numbers on every load", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  // What the worker sends back reaches the page as page time moves.
  const first = await stepUntilSettled(page.evaluate(() => window.workerDraws!()));
  await page.goto(fixtureUrl);
  expect(await stepUntilSettled(page.evaluate(() => window.workerDraws!()))).toEqual(
    first
  );
});

test("a worker from outside the test build fails the test", async ({ page }) => {
  await page.goto(fixtureUrl);
  await expect(
    page.evaluate(() => {
      const worker = new Worker(URL.createObjectURL(new Blob(["postMessage(1)"])));
      worker.terminate();
    })
  ).rejects.toThrow("outside the test build");
});

test("a key the browser would generate fails the test", async ({ page }) => {
  await page.goto(fixtureUrl);
  await expect(
    page.evaluate(() =>
      crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, false, ["sign"])
    )
  ).rejects.toThrow("whose randomness the test's seed does not reach");
});
