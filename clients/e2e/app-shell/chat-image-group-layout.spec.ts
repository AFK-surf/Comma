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
const fixtureRoot = resolve(currentDir, "fixtures/chat-image-group-layout");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/chat-image-group-layout-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    optimizeDeps: {
      include: ["shiki"],
    },
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error(
      "Chat image group layout fixture server did not expose a TCP port."
    );
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

const pendingPreviewCount = (page: Page) =>
  page.evaluate(() => window.chatImageGroupLayoutFixture!.pendingRefs().length);

const resolvePreview = (page: Page, index: number) =>
  page.evaluate((value) => window.chatImageGroupLayoutFixture!.resolve(value), index);

const resolveAllPreviews = (page: Page) =>
  page.evaluate(() => window.chatImageGroupLayoutFixture!.resolveAll());

// Stick-to-bottom re-pins a programmatic scrollTop, so the thread is moved
// the way a reader moves it: wheel steps over the scrollport. Each step also
// lets the preview observers classify the crossing, as they would for a user.
async function scrollThread(page: Page, viewport: Locator, position: "top" | "bottom") {
  const box = (await viewport.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  const settled = () =>
    viewport.evaluate(
      (element, where) =>
        where === "top"
          ? element.scrollTop <= 1
          : element.scrollTop + element.clientHeight >= element.scrollHeight - 1,
      position
    );
  for (let step = 0; step < 60 && !(await settled()); step += 1) {
    await page.mouse.wheel(0, position === "top" ? -160 : 160);
    await page.waitForTimeout(16);
  }
  expect(await settled()).toBe(true);
}

async function openThread(page: Page) {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("chat-image-group-layout-fixture");
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]');
  await expect(fixture.getByText("Drafting the report.")).toBeVisible();
  // The thread opens pinned to its latest turn, with both image messages past
  // the activation band; scrolling up is what starts their preview loads.
  await scrollThread(page, viewport, "top");
  await expect.poll(() => pendingPreviewCount(page)).toBe(7);
  return { fixture, viewport };
}

test("a settling multi-image message keeps one reserved footprint and mounts its group once", async ({
  page,
}) => {
  const { fixture } = await openThread(page);
  const deck = fixture.locator('[data-message-id="m1"]');
  const deckGroups = deck.locator(".chat-panel-image-group");
  const deckPlaceholder = deck.locator("[data-comma-image-group-placeholder]");
  const row = fixture.locator('[data-message-id="m3"]');
  const rowGroups = row.locator(".chat-panel-image-group");
  const rowPlaceholder = row.locator("[data-comma-image-group-placeholder]");

  await expect(deckGroups).toHaveCount(1);
  await expect(deckPlaceholder.locator(".chat-panel-image-group-card")).toHaveCount(1);

  // Three of four previews landing must not open a partial group beside the
  // placeholder: the message keeps its single collapsed-deck footprint.
  for (const index of [0, 1, 2]) {
    expect(await resolvePreview(page, index)).toBe(true);
    await expect(deckGroups).toHaveCount(1);
    await expect(deckPlaceholder).toHaveCount(1);
    await expect(deck.locator("img")).toHaveCount(0);
  }

  expect(await resolvePreview(page, 3)).toBe(true);
  await expect(deckPlaceholder).toHaveCount(0);
  await expect(deckGroups).toHaveCount(1);
  await expect(deck.getByRole("button", { name: "4 Images" })).toHaveAttribute(
    "aria-expanded",
    "false"
  );
  await expect(deck.locator(".chat-panel-image-group-card")).toHaveCount(4);
  await expect(deck.locator('img[alt="photo-1.png"]')).toBeVisible();

  // A flat row settles the same way: all three cards stay reserved until the
  // last preview lands, then the images appear together.
  await expect(rowPlaceholder.locator(".chat-panel-image-group-card")).toHaveCount(3);
  expect(await resolvePreview(page, 4)).toBe(true);
  expect(await resolvePreview(page, 5)).toBe(true);
  await expect(rowGroups).toHaveCount(1);
  await expect(rowPlaceholder).toHaveCount(1);
  await expect(row.locator("img")).toHaveCount(0);

  expect(await resolvePreview(page, 6)).toBe(true);
  await expect(rowPlaceholder).toHaveCount(0);
  await expect(row.locator("img")).toHaveCount(3);
  await expect(row.locator(".chat-panel-image-group-cards")).toHaveAttribute(
    "data-expanded",
    "true"
  );
});

test("a loaded deck retains its images and expanded layout across viewport re-entry", async ({
  page,
}) => {
  const { fixture, viewport } = await openThread(page);
  const deck = fixture.locator('[data-message-id="m1"]');
  const deckPlaceholder = deck.locator("[data-comma-image-group-placeholder]");
  await resolveAllPreviews(page);
  await expect(deck.locator('img[alt="photo-1.png"]')).toBeVisible();

  await deck.getByRole("button", { name: "4 Images" }).click();
  const hide = deck.getByRole("button", { name: "Hide" });
  await expect(hide).toHaveAttribute("aria-expanded", "true");
  await expect(deck.locator("img")).toHaveCount(4);

  const images = await deck.locator("img").elementHandles();
  const sources = await deck
    .locator("img")
    .evaluateAll((elements) => elements.map((element) => element.getAttribute("src")));
  // Scroll position gates new acquisitions, not the loaded deck's lifetime.
  await scrollThread(page, viewport, "bottom");
  await expect(deckPlaceholder).toHaveCount(0);
  await expect(deck.locator("img")).toHaveCount(4);
  await expect(deck.locator(".chat-panel-image-group-cards")).toHaveAttribute(
    "data-expanded",
    "true"
  );

  await scrollThread(page, viewport, "top");
  expect(await pendingPreviewCount(page)).toBe(0);
  await expect(deckPlaceholder).toHaveCount(0);
  expect(
    await deck
      .locator("img")
      .evaluateAll((elements) => elements.map((element) => element.getAttribute("src")))
  ).toEqual(sources);
  for (let index = 0; index < images.length; index += 1) {
    expect(
      await deck
        .locator("img")
        .nth(index)
        .evaluate((element, original) => element === original, images[index]!)
    ).toBe(true);
  }
  await expect(deck.getByRole("button", { name: "Hide" })).toHaveAttribute(
    "aria-expanded",
    "true"
  );
  await expect(deck.locator("img")).toHaveCount(4);
});
