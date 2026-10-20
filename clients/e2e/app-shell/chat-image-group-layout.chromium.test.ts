import { expect, test, type Locator, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

useFixture(
  fixtureMount(
    new URL("./fixtures/chat-image-group-layout/src/main.tsx", import.meta.url)
  )
);
const fixtureUrl = "http://fixture.test/";

const pendingPreviewCount = (page: Page) =>
  page.evaluate(() => window.chatImageGroupLayoutFixture!.pendingRefs().length);

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
