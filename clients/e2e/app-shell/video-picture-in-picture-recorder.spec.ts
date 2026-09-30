import { expect, test, type Locator, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/video-pip-recorder");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/video-pip-recorder-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Video picture in picture fixture did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

type Box = { x: number; y: number; width: number; height: number };

const box = async (locator: Locator): Promise<Box> => (await locator.boundingBox())!;

const centerOf = (rect: Box) => ({
  x: rect.x + rect.width / 2,
  y: rect.y + rect.height / 2,
});

const overlaps = (a: Box, b: Box) =>
  a.x < b.x + b.width &&
  b.x < a.x + a.width &&
  a.y < b.y + b.height &&
  b.y < a.y + a.height;

const expectInside = (inner: Box, outer: Box) => {
  expect(inner.x).toBeGreaterThanOrEqual(outer.x);
  expect(inner.y).toBeGreaterThanOrEqual(outer.y);
  expect(inner.x + inner.width).toBeLessThanOrEqual(outer.x + outer.width);
  expect(inner.y + inner.height).toBeLessThanOrEqual(outer.y + outer.height);
};

/** Where the window rests once its entrance or slide has finished. */
const settled = async (floating: Locator) => {
  await expect
    .poll(() => floating.evaluate((element) => element.getAnimations().length))
    .toBe(0);
  return box(floating);
};

/** Which floating surface a pointer at this point reaches. */
const topmostAt = (page: Page, point: { x: number; y: number }) =>
  page.evaluate(({ x, y }) => {
    const hit = document.elementFromPoint(x, y);
    if (hit?.closest('[aria-label="Meeting recorder"]')) return "recorder";
    if (hit?.closest('[data-testid="chat-panel-video-pip"]')) return "window";
    return hit?.tagName ?? "nothing";
  }, point);

test("a floating video keeps clear of the meeting recorder, which stays on top", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const area = await box(page.getByTestId("route-area"));
  const recorder = page.getByLabel("Meeting recorder", { exact: true });
  const stop = recorder.getByRole("button", { name: "Stop recording", exact: true });
  const floating = page.getByTestId("chat-panel-video-pip");
  const video = page.locator("video");
  const wheel = async (deltaY: number, steps: number) => {
    // Over the transcript, clear of both floating surfaces.
    await page.mouse.move(area.x + 360, area.y + 400);
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, deltaY);
      await page.waitForTimeout(30);
    }
  };

  await expect
    .poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState))
    .toBeGreaterThan(1);
  await video.evaluate((element: HTMLVideoElement) => {
    element.muted = true;
    // The walk below outlasts the clip.
    element.loop = true;
  });
  await page.getByRole("button", { name: "Play video", exact: true }).focus();
  await page.keyboard.press("Enter");
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());

  await wheel(300, 6);
  await expect(floating).toBeVisible();
  const recorded = await box(recorder);
  const docked = await settled(floating);
  expect(overlaps(docked, recorded)).toBe(false);

  // Dragged over the recorder, the window passes under it.
  const grab = centerOf(docked);
  const target = centerOf(recorded);
  await page.mouse.move(grab.x, grab.y);
  await page.mouse.down();
  await page.mouse.move(target.x, target.y, { steps: 12 });
  const dropped = await box(floating);
  expect(overlaps(dropped, recorded)).toBe(true);
  expect(await topmostAt(page, centerOf(await box(stop)))).toBe("recorder");

  // Dropped there, it slides off the recording controls.
  await page.mouse.up();
  const cleared = await settled(floating);
  expect(overlaps(cleared, recorded)).toBe(false);
  expectInside(cleared, area);

  // A later window opens where the reader left this one, still clear.
  await wheel(-300, 8);
  await page.getByRole("button", { name: "Play here", exact: true }).click();
  await expect(floating).toHaveCount(0);
  await wheel(300, 6);
  await expect(floating).toBeVisible();
  const reopened = await settled(floating);
  expect(overlaps(reopened, recorded)).toBe(false);

  // The recorder moved onto the window: the window yields, not the recorder.
  const handle = centerOf(
    await box(recorder.getByText("Recording ongoing", { exact: true }))
  );
  const from = centerOf(recorded);
  const onto = centerOf(reopened);
  await page.mouse.move(handle.x, handle.y);
  await page.mouse.down();
  await page.mouse.move(handle.x + onto.x - from.x, handle.y + onto.y - from.y, {
    steps: 12,
  });
  await page.mouse.up();
  const moved = await box(recorder);
  expect(overlaps(moved, reopened)).toBe(true);
  const yielded = await settled(floating);
  expect(overlaps(yielded, moved)).toBe(false);
  expectInside(yielded, area);

  // The controls stay reachable, and with the recorder gone the window goes
  // back to where the reader put it.
  await stop.click();
  await expect(recorder).toHaveCount(0);
  const restored = await settled(floating);
  expect(restored.x).toBeCloseTo(dropped.x, 0);
  expect(restored.y).toBeCloseTo(dropped.y, 0);
  expect(await video.evaluate((element: HTMLVideoElement) => element.paused)).toBe(
    false
  );
});
