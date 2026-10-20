import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { pageWorld, useNodeRealm } from "./support/world";

// A page, its worker and the server they ask are three realms: the server has
// delays of its own, and a response reaches the page when the network
// delivers it. As realms of one world they run one at a time on the world's
// time; a request, and the head, each write and the end of its response, are
// messages the world hands over in the order they were sent.
const stub = useNodeRealm<{ origin: string }>(
  "stub",
  "e2e/app-shell/fixtures/world-http/stub.ts"
);
useFixture(
  fixtureMount(new URL("./fixtures/world-http/src/main.ts", import.meta.url)),
  { world: { servers: () => [stub()] }, warmUp: ["http://fixture.test/"] }
);
const fixtureUrl = "http://fixture.test/";

test("a streamed reply, an answer and a timer arrive on one schedule", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  await page.evaluate((origin) => window.worldHttp!.start(origin), stub().origin);
  world.touched("page");
  const lines = () => page.evaluate(() => [...window.worldHttp!.log]);
  await world.until(async () => (await lines()).at(-1)?.endsWith(" end"), {
    what: "the end of the streamed reply",
  });
  // The server writes a part of the reply every 20 ms and answers each echo
  // 30 ms after it was asked; the page's timer is due at 40 ms. At one time,
  // the page runs before the server.
  expect(await lines()).toEqual([
    "20 head 200",
    "20 data: part 1 of page",
    '30 echo {"echo":"from the page","order":2}',
    '30 worker: echo {"echo":"from the worker","order":2}',
    "40 timer",
    "40 data: part 2 of page",
    "60 data: part 3 of page",
    "60 end",
  ]);
  expect(await stub().call("seen")).toEqual([
    "echo from the page",
    "echo from the worker",
    "closed page",
  ]);
});

test("a request the page aborts closes on the server when the world says", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  await page.evaluate(
    (origin) => window.worldHttp!.abortAfter(origin, 30),
    stub().origin
  );
  world.touched("page");
  await world.advance(100);
  expect(await page.evaluate(() => [...window.worldHttp!.log])).toEqual([
    "20 head 200",
    "20 data: part 1 of aborted",
    "30 failed AbortError",
  ]);
  expect(await stub().call("seen")).toEqual(["closed aborted"]);
  expect(await stub().call("open")).toBe(0);
  expect(world.log().filter((line) => / (sent|receives) abort /.test(line))).toEqual([
    expect.stringContaining("page rests, sent abort GET /reply?of=aborted to stub"),
    expect.stringContaining("stub receives abort GET /reply?of=aborted from page"),
  ]);
});

test("a request the browser sends after six later ones is still answered first", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  await page.evaluate(
    (origin) => window.worldHttp!.firstLeavesLast(origin),
    stub().origin
  );
  world.touched("page");
  const lines = () => page.evaluate(() => [...window.worldHttp!.log]);
  await world.until(async () => (await lines()).length === 7, {
    what: "the seven echoes",
  });
  // The server answers in the order the page asked, not in the order the
  // browser sent: the six later requests hold every connection the browser
  // opens to it, and the first can leave only when one of them gives way.
  const asked = ["first", ...[1, 2, 3, 4, 5, 6].map((later) => `later ${later}`)];
  expect(await stub().call("seen")).toEqual(asked.map((body) => `echo ${body}`));
  expect(await lines()).toEqual(asked.map((body) => `0 echo ${body}`));
});

test("a request the browser fails before it leaves fails the world with the browser's failure", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const world = pageWorld();
  await page.evaluate((origin) => window.worldHttp!.refused(origin), stub().origin);
  world.touched("page");
  // The server would wait for the request the page told the world of: the
  // page's realm tells it that the browser failed the request, and how.
  await expect(world.settle()).rejects.toThrow(
    /Request page\.\d+\.1 \(GET \/echo\) of page did not reach the realm: the browser failed it \(TypeError: /
  );
});
