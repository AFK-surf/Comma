import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { testClock } from "./support/virtual-time";

useFixture(fixtureMount(new URL("./fixtures/plugins/src/main.tsx", import.meta.url)));
const fixtureUrl = "http://fixture.test/";

test.beforeEach(async ({ page }) => {
  await page.goto(fixtureUrl);
  await expect(page.getByRole("heading", { name: "Plugins" })).toBeVisible();
});

test("plugin catalog preserves keyboard focus through expansion", async ({ page }) => {
  const showAll = page.getByRole("button", { name: /Show all/ }).first();

  await showAll.focus();
  await expect(showAll).toBeFocused();
  await showAll.press("Enter");

  const revealedPlugin = page.getByRole("button", {
    name: "View GitHub plugin details",
  });
  await expect(revealedPlugin).toBeFocused();

  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Add GitHub" })).toBeFocused();
});

test("plugin preview icons remain visible through pointer expansion", async ({
  page,
}) => {
  const showAll = page.getByRole("button", { name: /Show all/ }).first();
  const flights = page.locator('[data-slot="plugin-artwork-flight"]');
  const revealedGitHubArtwork = page
    .locator('[data-slot="plugin-list-item"][data-plugin-id="github"]')
    .locator('[data-slot="plugin-artwork"]');

  expect(
    await showAll.evaluate(async (button) => {
      button.dispatchEvent(
        new MouseEvent("click", { bubbles: true, detail: 1, view: window })
      );
      await testClock().advanceFrames(1);
      return {
        flightCount: document.querySelectorAll('[data-slot="plugin-artwork-flight"]')
          .length,
        flightIconCount: document.querySelectorAll(
          '[data-slot="plugin-artwork-flight"] svg'
        ).length,
        targetVisibility: getComputedStyle(
          document.querySelector<HTMLElement>(
            '[data-slot="plugin-list-item"][data-plugin-id="github"] [data-slot="plugin-artwork"]'
          )!
        ).visibility,
      };
    })
  ).toEqual({
    flightCount: 2,
    flightIconCount: 4,
    targetVisibility: "hidden",
  });

  await expect(flights).toHaveCount(0);
  await expect(revealedGitHubArtwork).toHaveCSS("visibility", "visible");
});

test("large plugin expansion reveals rows in order at an intermediate frame", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const originalAnimate = Element.prototype.animate;
    const revealAnimations: Animation[] = [];

    (
      window as typeof window & {
        commaPluginRevealAnimations?: Animation[];
      }
    ).commaPluginRevealAnimations = revealAnimations;
    Element.prototype.animate = function (
      keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
      options?: number | KeyframeAnimationOptions
    ) {
      const animation = originalAnimate.call(this, keyframes, options);

      if (this instanceof HTMLElement && this.dataset.slot === "plugin-list-item") {
        animation.pause();
        animation.currentTime = 0;
        revealAnimations.push(animation);
      }

      return animation;
    };
  });
  await page.goto(new URL("?hiddenPluginCount=10", fixtureUrl).toString());

  const showAll = page.getByRole("button", { name: /Show all/ }).first();
  await expect(showAll.locator("[data-plugin-id]")).toHaveCount(3);

  const snapshot = await showAll.evaluate(async (button) => {
    button.dispatchEvent(
      new MouseEvent("click", { bubbles: true, detail: 1, view: window })
    );
    // React commits the click.
    await testClock().advance(1);

    const revealAnimations =
      (
        window as typeof window & {
          commaPluginRevealAnimations?: Animation[];
        }
      ).commaPluginRevealAnimations ?? [];
    for (const animation of revealAnimations) {
      animation.currentTime = 60;
    }
    await testClock().advanceFrames(1);

    const rows = Array.from(
      document.querySelectorAll<HTMLElement>(
        '.comma-plugin-reveal [data-slot="plugin-list-item"]'
      )
    );
    const opacities = rows.map((row) => Number(getComputedStyle(row).opacity));
    const firstTransparentIndex = opacities.findIndex((opacity) => opacity <= 0.01);
    const firstOpaqueAfterTransparent = opacities.findIndex(
      (opacity, index) => index > firstTransparentIndex && opacity >= 0.99
    );
    const result = {
      animationCount: revealAnimations.length,
      firstOpaqueAfterTransparent,
      firstTransparentIndex,
      opacities,
      rowIds: rows.map((row) => row.dataset.pluginId),
    };

    for (const animation of revealAnimations) {
      animation.cancel();
    }
    return result;
  });

  expect(snapshot.rowIds).toHaveLength(10);
  expect(snapshot.animationCount).toBe(10);
  expect(snapshot.opacities[0]).toBeGreaterThan(snapshot.opacities[1]!);
  expect(snapshot.opacities[1]).toBeGreaterThan(0);
  expect(snapshot.firstTransparentIndex).toBe(2);
  expect(snapshot.firstOpaqueAfterTransparent).toBe(-1);
});

test("plugin search exposes a visible keyboard focus treatment", async ({ page }) => {
  const search = page.getByRole("textbox", { name: "Search plugins" });
  const wrapper = search.locator("..");
  const restingShadow = await wrapper.evaluate(
    (element) => getComputedStyle(element).boxShadow
  );

  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  await expect(search).toBeFocused();

  await expect
    .poll(() => wrapper.evaluate((element) => getComputedStyle(element).boxShadow))
    .not.toBe(restingShadow);
});

test("plugin search keeps its resting outline on pointer focus", async ({ page }) => {
  const search = page.getByRole("textbox", { name: "Search plugins" });
  const wrapper = search.locator("..");
  const restingShadow = await wrapper.evaluate(
    (element) => getComputedStyle(element).boxShadow
  );

  await search.click();
  await expect(search).toBeFocused();
  // Let the wrapper's shadow transition settle before reading it.
  await page.waitForTimeout(300);

  expect(await wrapper.evaluate((element) => getComputedStyle(element).boxShadow)).toBe(
    restingShadow
  );
});
