import { expect, test, type Locator, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { stepUntilAnimationsFinish } from "./support/virtual-time";

useFixture(
  fixtureMount(new URL("./fixtures/notch-width/src/main.tsx", import.meta.url))
);
const fixtureUrl = "http://fixture.test/";

const range = { min: 32, default: 156, max: 240 };

async function openFixture(page: Page) {
  await page.goto(fixtureUrl);
  const slider = page.getByRole("slider", { name: "Notch width" });
  await expect(slider).toHaveAttribute("aria-valuenow", String(range.default));
  // Settings opens with a short zoom; the field is measured once it has landed.
  await stepUntilAnimationsFinish();
  return slider;
}

interface InvalidationEvent {
  name: string;
  args?: {
    data?: {
      changedPseudo?: string;
      invalidationList?: { id: string }[];
      invalidationSet?: string;
      reason?: string;
    };
  };
}

/**
 * How often a :has() rule restyles a whole subtree while `act` runs. A rule
 * whose subject is the :has() element itself restyles only that element, so it
 * is not counted.
 */
async function hasRuleSubtreeRestyles(page: Page, act: () => Promise<void>) {
  const cdp = await page.context().newCDPSession(page);
  const events: InvalidationEvent[] = [];
  // The protocol types trace events as flat string maps; their args are objects.
  // A chunk can hold more events than a call takes arguments: no spread.
  cdp.on("Tracing.dataCollected", ({ value }) => {
    for (const event of value as unknown as typeof events) events.push(event);
  });
  const complete = new Promise<void>((done) =>
    cdp.once("Tracing.tracingComplete", () => done())
  );
  await cdp.send("Tracing.start", {
    traceConfig: {
      includedCategories: [
        "disabled-by-default-devtools.timeline.invalidationTracking",
      ],
    },
    transferMode: "ReportEvents",
  });
  await act();
  await cdp.send("Tracing.end", {
    eventNames: [
      "ScheduleStyleInvalidationTracking",
      "StyleInvalidatorInvalidationTracking",
    ],
  });
  await complete;
  await cdp.detach();
  const hasSets = new Set(
    events
      .filter(
        (event) =>
          event.name === "ScheduleStyleInvalidationTracking" &&
          event.args?.data?.changedPseudo === "has"
      )
      .map((event) => event.args?.data?.invalidationSet)
  );
  return events.filter(
    (event) =>
      event.name === "StyleInvalidatorInvalidationTracking" &&
      event.args?.data?.reason === "Invalidation set invalidates subtree" &&
      event.args.data.invalidationList?.some((set) => hasSets.has(set.id))
  ).length;
}

const commits = (page: Page) => page.evaluate(() => window.notchWidthCommits ?? []);
const previews = (page: Page) => page.evaluate(() => window.notchWidthPreviews ?? []);
const shell = (page: Page) => page.locator(".comma-notch-width__shell");
const box = async (locator: Locator) => {
  const rect = await locator.boundingBox();
  if (!rect) throw new Error("Expected a visible element.");
  return rect;
};

/** Where along the slider field a width sits: the field is the whole range. */
async function fieldScale(page: Page) {
  const field = await box(page.getByRole("slider", { name: "Notch width" }));
  const pixelsPerPoint = field.width / (range.max - range.min);
  return {
    field,
    pixelsPerPoint,
    xFor: (width: number) => field.x + (width - range.min) * pixelsPerPoint,
    y: Math.round(field.y + field.height / 2),
  };
}

test("the slider field sizes the Notch around the notch and saves where a drag lands", async ({
  page,
}) => {
  const slider = await openFixture(page);
  const { field, pixelsPerPoint, xFor, y } = await fieldScale(page);
  const rest = await box(shell(page));

  // Taking the field at its edge and pulling right widens both sides at once.
  const start = Math.round(xFor(range.default));
  await page.mouse.move(start, y);
  await page.mouse.down();
  await page.mouse.move(start + Math.round(20 * pixelsPerPoint), y, { steps: 6 });
  const wider = await box(shell(page));
  expect(wider.width).toBeGreaterThan(rest.width + 1);
  expect(wider.x + wider.width / 2).toBeCloseTo(rest.x + rest.width / 2, 0);
  // Nothing is saved while the field is still held.
  expect(await commits(page)).toEqual([]);

  // Far past the end the field stretches a little, and no further.
  await page.mouse.move(start + 800, y, { steps: 20 });
  const stretched = await box(slider);
  expect(stretched.width).toBeGreaterThan(field.width + 1);
  expect(stretched.width).toBeLessThan(field.width * 1.03);

  // Let go: it settles on the widest setting, which is saved once, and the
  // whole Notch stays in the preview.
  await page.mouse.up();
  await expect(slider).toHaveAttribute("aria-valuenow", String(range.max));
  await expect.poll(async () => (await box(slider)).width).toBeCloseTo(field.width, 0);
  expect(await commits(page)).toEqual([range.max]);
  const stage = await box(page.locator(".comma-notch-width__stage"));
  const widest = await box(shell(page));
  expect(widest.x).toBeGreaterThan(stage.x);
  expect(widest.x + widest.width).toBeLessThan(stage.x + stage.width);

  // Pressing anywhere sends the width there.
  await page.mouse.click(Math.round(xFor(64)), y);
  await expect
    .poll(async () => Number(await slider.getAttribute("aria-valuenow")))
    .toBeLessThanOrEqual(65);
  expect((await commits(page)).length).toBe(2);
  await expect(page.getByRole("button", { name: "Reset" })).toBeEnabled();
});

test("a drag that leaves the field before its first move still ends on release", async ({
  page,
}) => {
  const slider = await openFixture(page);
  const { field, xFor, y } = await fieldScale(page);
  const root = page.locator(
    '[data-slot="notch-width-setting"] [data-slot="settings-slider-field"]'
  );

  // The very first move lands well below the field, and so does the release.
  await page.mouse.move(Math.round(xFor(range.default)), y);
  await page.mouse.down();
  await page.mouse.move(
    Math.round(xFor(200)),
    Math.round(field.y + field.height + 200)
  );
  await page.mouse.up();
  await expect(root).toHaveAttribute("data-dragging", "false");
  await expect(slider).toHaveAttribute("aria-valuenow", "200");
  expect(await commits(page)).toEqual([200]);

  // Hovering the field afterwards moves nothing, and the keys work again.
  await page.mouse.move(Math.round(xFor(64)), y, { steps: 4 });
  await expect(slider).toHaveAttribute("aria-valuenow", "200");
  await slider.focus();
  await page.keyboard.press("ArrowLeft");
  await expect(slider).toHaveAttribute("aria-valuenow", "196");
});

test("Settings leaving the page under a held drag keeps the dragged width", async ({
  page,
}) => {
  await openFixture(page);
  const { xFor, y } = await fieldScale(page);

  await page.mouse.move(Math.round(xFor(range.default)), y);
  await page.mouse.down();
  await page.mouse.move(Math.round(xFor(200)), y, { steps: 6 });
  expect(await commits(page)).toEqual([]);
  // The held field has the pointer, so the category changes the way a
  // keyboard shortcut would change it.
  await page
    .getByRole("button", { exact: true, name: "Notifications" })
    .dispatchEvent("click");
  await expect(page.getByRole("slider", { name: "Notch width" })).toHaveCount(0);
  expect(await commits(page)).toEqual([200]);
  await page.mouse.up();
});

test("the default holds a light drag, Reset restores it, and the Notch previews in place", async ({
  page,
}) => {
  const slider = await openFixture(page);
  const { pixelsPerPoint, xFor, y } = await fieldScale(page);
  const root = page.locator(
    '[data-slot="notch-width-setting"] [data-slot="settings-slider-field"]'
  );
  const reset = page.getByRole("button", { name: "Reset" });
  await expect(reset).toBeDisabled();
  const start = Math.round(xFor(range.default));

  // Within four points of the default, the width stays on it.
  await page.mouse.move(start, y);
  await page.mouse.down();
  await page.mouse.move(start + Math.floor(3 * pixelsPerPoint), y, { steps: 3 });
  await expect(root).toHaveAttribute("data-snapped", "true");
  const outward = Math.round(24 * pixelsPerPoint);
  const widened = Math.round(range.default + outward / pixelsPerPoint);
  await page.mouse.move(start + outward, y, { steps: 4 });
  await expect(root).toHaveAttribute("data-snapped", "false");
  await page.mouse.up();
  await expect(slider).toHaveAttribute("aria-valuenow", String(widened));

  await reset.click();
  await expect(slider).toHaveAttribute("aria-valuenow", String(range.default));
  expect(await commits(page)).toEqual([widened, range.default]);
  await expect(reset).toBeDisabled();

  // Arrow keys step it; the real Notch then shows exactly that width.
  await slider.focus();
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  await expect(slider).toHaveAttribute("aria-valuenow", String(range.default - 8));
  await page.getByRole("button", { name: "Preview on notch" }).click();
  expect(await previews(page)).toEqual([range.default - 8]);
  expect(await commits(page)).toEqual([widened, range.default, range.default - 8]);
});

test("content changing inside Settings never has a :has() rule restyle the dialog", async ({
  page,
}) => {
  const slider = await openFixture(page);
  const { pixelsPerPoint, xFor, y } = await fieldScale(page);
  const start = Math.round(xFor(64));
  await page.mouse.move(start, y);
  await page.mouse.down();
  await page.mouse.move(start + 1, y);

  // A :has() anchored on the dialog restyles all of it for every node added or
  // removed anywhere inside, which drops frames while a drag or a fold runs.
  const restyles = await hasRuleSubtreeRestyles(page, async () => {
    for (let step = 1; step <= 30; step++) {
      await page.mouse.move(start + Math.round(step * 2 * pixelsPerPoint), y);
    }
    await page.mouse.up();
    await expect
      .poll(async () => Number(await slider.getAttribute("aria-valuenow")))
      .toBeGreaterThan(120);

    // Another category replaces the whole panel; coming back mounts it anew.
    await page.getByRole("button", { exact: true, name: "Notifications" }).click();
    await expect(page.locator(".comma-notch-width")).toHaveCount(0);
    await page.getByRole("button", { exact: true, name: "General" }).click();
    await expect(slider).toBeVisible();
  });

  expect(restyles).toBe(0);
});
