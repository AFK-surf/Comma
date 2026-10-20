import { expect, test, type Locator, type Page } from "@playwright/test";
import {
  installVirtualTime,
  type VirtualTime,
} from "../../../e2e/helpers/virtual-time";

const TOOLBAR_STORY =
  "/iframe.html?id=app-components-right-sidebar--browser-toolbar-history&viewMode=story";
const BROWSER_STORY =
  "/iframe.html?id=app-components-right-sidebar--browser-selected&viewMode=story";

/** Reads the live animated value of a transform property on a pressed glyph. */
const readMotion = (glyph: Locator, property: "rotate" | "translate") =>
  glyph.evaluate(
    (element, name) =>
      Number.parseFloat(getComputedStyle(element).getPropertyValue(name as string)) ||
      0,
    property
  );

/**
 * Opens the loading browser toolbar, then stops the page clock. The story's
 * play step runs on real timers, so the clock starts after it.
 */
const openBrowserStory = async (page: Page): Promise<VirtualTime> => {
  await page.goto(BROWSER_STORY);
  await expect(page.getByRole("button", { name: "Stop loading" })).toBeVisible();
  return installVirtualTime(page);
};

/** Steps until the reload glyph has no rotate transition left. */
const stepUntilRotationRetires = async (time: VirtualTime): Promise<void> => {
  await time.advanceUntil(
    () =>
      !document
        .querySelector(".comma-right-sidebar-browser-reload .comma-icon-press-refresh")
        ?.getAnimations()
        .some(
          (animation) =>
            animation instanceof CSSTransition &&
            animation.transitionProperty === "rotate"
        )
  );
  // A retired transition's transitionend runs with the next rendered frame.
  await time.advanceFrames(1);
};

/** Presses and holds, so the glyph has arrived rather than being mid-flight. */
const readWhileHeld = async (
  page: Page,
  time: VirtualTime,
  button: Locator,
  glyph: Locator,
  property: "rotate" | "translate"
) => {
  const box = await button.boundingBox();
  if (!box) throw new Error("Navigation button did not render");
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await time.advance(200);
  const held = await readMotion(glyph, property);
  await page.mouse.up();
  return held;
};

test("navigation arrows travel along the axis their own glyph points", async ({
  page,
}) => {
  const time = await installVirtualTime(page);
  await page.goto(TOOLBAR_STORY);

  const back = page.getByRole("button", { name: "Back" });
  const forward = page.getByRole("button", { name: "Forward" });
  await expect(back).toBeVisible();

  const shift = await page.evaluate(() =>
    Number.parseFloat(
      getComputedStyle(document.documentElement).getPropertyValue(
        "--motion-distance-nav-press-shift"
      )
    )
  );
  expect(shift).toBeGreaterThan(0);

  const backHeld = await readWhileHeld(
    page,
    time,
    back,
    back.locator(".comma-icon-press-back"),
    "translate"
  );
  const forwardHeld = await readWhileHeld(
    page,
    time,
    forward,
    forward.locator(".comma-icon-press-forward"),
    "translate"
  );

  // Back leads left because that is where it points; forward mirrors it.
  expect(backHeld).toBeCloseTo(-shift, 1);
  expect(forwardHeld).toBeCloseTo(shift, 1);

  // And both come home once the press ends.
  await time.advanceUntil(
    () => document.querySelector(".comma-icon-press-back")?.getAnimations().length === 0
  );
  expect(await readMotion(back.locator(".comma-icon-press-back"), "translate")).toBe(0);
});

test("reload finishes its turn before the stop X takes over", async ({ page }) => {
  const time = await openBrowserStory(page);

  // The story's play step leaves the toolbar loading before its motion may have
  // ended. Stop loading, then retire its rotation before capturing a new click.
  await page.getByRole("button", { name: "Stop loading" }).click();
  const reload = page.getByRole("button", { name: "Reload" });
  await expect(reload).toBeVisible();
  const glyph = page.locator(
    ".comma-right-sidebar-browser-reload .comma-icon-press-refresh"
  );
  await stepUntilRotationRetires(time);
  expect(await readMotion(glyph, "rotate")).toBe(0);

  const sweep = await page.evaluate(
    () =>
      Number.parseFloat(
        getComputedStyle(document.documentElement).getPropertyValue(
          "--motion-rotate-refresh-press"
        )
      ) || 0
  );
  expect(sweep).toBeGreaterThan(0);

  // Capture the actual phase endings and handoff of a click.
  await page.evaluate(() => {
    const button = document.querySelector<HTMLButtonElement>(
      'button[aria-label="Reload"]'
    );
    const target = button?.querySelector<SVGElement>(".comma-icon-press-refresh");
    const slot = target?.parentElement;
    if (!target || !slot) throw new Error("Reload glyph did not render");

    const capture = {
      rotateEnds: [] as { rotate: number; time: number }[],
      swaps: [] as { rotate: number; time: number }[],
    };
    Object.assign(window, { commaReloadPressMotion: capture });
    const readRotate = () => Number.parseFloat(getComputedStyle(target).rotate) || 0;
    target.addEventListener("transitionend", (event) => {
      if (event.propertyName !== "rotate") return;
      capture.rotateEnds.push({ rotate: readRotate(), time: performance.now() });
    });
    new MutationObserver(() => {
      if (slot.dataset["visible"] !== "false") return;
      capture.swaps.push({ rotate: readRotate(), time: performance.now() });
    }).observe(slot, { attributeFilter: ["data-visible"], attributes: true });
  });

  // As fast a click as a person can make — far shorter than the sweep.
  await reload.click();
  await time.advanceUntil(() => {
    const capture = (
      window as unknown as {
        commaReloadPressMotion: { rotateEnds: unknown[]; swaps: unknown[] };
      }
    ).commaReloadPressMotion;
    return capture.rotateEnds.length >= 2 && capture.swaps.length > 0;
  });

  const capture = await page.evaluate(
    () =>
      (
        window as unknown as {
          commaReloadPressMotion: {
            rotateEnds: { rotate: number; time: number }[];
            swaps: { rotate: number; time: number }[];
          };
        }
      ).commaReloadPressMotion
  );
  // The sweep lands in full even though the press ended long before it would have.
  expect(capture.rotateEnds).toHaveLength(2);
  expect(capture.rotateEnds[0]!.rotate).toBeCloseTo(sweep, 1);
  // The recoil lands before the glyph is handed off.
  expect(capture.rotateEnds[1]!.rotate).toBeCloseTo(0, 1);

  // Only once the glyph is home does the stop X take over.
  expect(capture.swaps).toHaveLength(1);
  expect(capture.swaps[0]!.rotate).toBeCloseTo(0, 1);
  expect(capture.swaps[0]!.time).toBeGreaterThanOrEqual(capture.rotateEnds[1]!.time);
  await expect(page.getByRole("button", { name: "Stop loading" })).toBeVisible();
});

for (const phase of ["travel", "recoil"] as const) {
  for (const settlement of ["finish", "cancel"] as const) {
    test(`reload waits for ${phase} beyond its watchdog (${settlement})`, async ({
      page,
    }) => {
      const time = await openBrowserStory(page);
      await page.getByRole("button", { name: "Stop loading" }).click();
      const reload = page.locator(".comma-right-sidebar-browser-reload");
      const glyph = reload.locator(".comma-icon-press-refresh");
      await stepUntilRotationRetires(time);

      await glyph.evaluate(
        (element, { pausedPhase, dropEvents }) => {
          if (dropEvents) {
            element.addEventListener("transitionend", (event) =>
              event.stopPropagation()
            );
          }
          const button = element.closest("button")!;
          const observer = new MutationObserver(() => {
            if (button.hasAttribute("data-press-held") !== (pausedPhase === "travel"))
              return;
            const animation = element
              .getAnimations()
              .find(
                (candidate) =>
                  candidate instanceof CSSTransition &&
                  candidate.transitionProperty === "rotate"
              );
            if (!animation) throw new Error("Reload transition did not start");
            observer.disconnect();
            animation.pause();
            Object.assign(window, { pausedReloadMotion: animation });
          });
          observer.observe(button, { attributeFilter: ["data-press-held"] });
        },
        { pausedPhase: phase, dropEvents: settlement === "cancel" }
      );

      await reload.click();
      await time.advanceUntil(() =>
        Boolean(
          (window as unknown as { pausedReloadMotion?: Animation }).pausedReloadMotion
        )
      );
      await page.evaluate(async (pausedPhase) => {
        const animation = (window as unknown as { pausedReloadMotion: Animation })
          .pausedReloadMotion;
        await animation.ready;
        const duration = Number(animation.effect!.getTiming().duration);
        animation.currentTime = duration * (pausedPhase === "travel" ? 0.5 : 0.8);
      }, phase);

      // Outlive the watchdog while the real CSS transition is unfinished.
      // Elapsed time must not hand the glyph off.
      await time.advance(350);
      if (phase === "travel")
        expect(await reload.getAttribute("data-press-held")).not.toBeNull();
      expect(await glyph.locator("..").getAttribute("data-visible")).toBe("true");
      if (phase === "recoil")
        expect(await readMotion(glyph, "rotate")).toBeLessThan(-1);

      await page.evaluate((completion) => {
        const animation = (window as unknown as { pausedReloadMotion: Animation })
          .pausedReloadMotion;
        if (completion === "finish") animation.play();
        else animation.cancel();
      }, settlement);
      // The settled phase hands off, through its recoil, to the stop X.
      await time.advanceUntil(
        () =>
          document.querySelector<HTMLElement>(
            ".comma-right-sidebar-browser-reload .comma-icon-press-refresh"
          )?.parentElement?.dataset.visible === "false"
      );
      expect(await readMotion(glyph, "rotate")).toBeCloseTo(0, 1);
    });
  }
}

test("keyboard reload swaps immediately without starting pointer motion", async ({
  page,
}) => {
  const time = await openBrowserStory(page);
  await page.getByRole("button", { name: "Stop loading" }).click();
  const reload = page.getByRole("button", { name: "Reload" });
  await expect(reload).toBeVisible();
  const glyph = page.locator(
    ".comma-right-sidebar-browser-reload .comma-icon-press-refresh"
  );
  await stepUntilRotationRetires(time);
  expect(await readMotion(glyph, "rotate")).toBe(0);
  await reload.focus();
  await page.keyboard.down("Space");

  // Chromium applies :active while Space is held. Inspect the transition's
  // destination rather than depending on a compositor frame landing in this
  // short 50ms interval: keyboard activation must not even target a turn.
  const rotationTargets = await glyph.evaluate((element) =>
    element.getAnimations().flatMap((animation) => {
      const effect = animation.effect;
      if (!(effect instanceof KeyframeEffect)) return [];
      return effect
        .getKeyframes()
        .map((frame) => (typeof frame.rotate === "string" ? frame.rotate : ""));
    })
  );
  expect(rotationTargets.some((target) => target !== "" && target !== "0deg")).toBe(
    false
  );

  await page.keyboard.up("Space");
  await expect(page.getByRole("button", { name: "Stop loading" })).toBeVisible();
  await expect(glyph.locator("..")).toHaveAttribute("data-visible", "false");
});
