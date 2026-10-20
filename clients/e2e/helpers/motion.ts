import { expect, type Locator, type Page } from "@playwright/test";

/** Wait for finite UI motion without waiting on a loading shimmer or caret. */
export async function waitForSettledMotion(locator: Locator): Promise<void> {
  await expect(locator).toBeVisible();
  // Let mount-time entry styles start their transitions before checking them.
  await locator.evaluate(
    () =>
      new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      )
  );
  await expect
    .poll(() =>
      locator.evaluate(
        (element) =>
          element
            .getAnimations({ subtree: true })
            .filter(
              (animation) =>
                (animation.pending || animation.playState === "running") &&
                animation.effect?.getComputedTiming().iterations !== Infinity
            ).length
      )
    )
    .toBe(0);
}

/**
 * Waits, on no timer, for the finite animations and transitions running now
 * to finish: the ones the last change started. Reading layout first starts
 * the transitions it asked for. Animations that start later (a shimmer's next
 * sweep) are not waited for; a page that keeps starting them never settles.
 */
export async function waitForFiniteAnimations(page: Page): Promise<void> {
  await page.evaluate(async () => {
    void document.documentElement.offsetHeight;
    const running = document
      .getAnimations()
      .filter(
        (animation) =>
          animation.playState === "running" &&
          animation.effect?.getComputedTiming().iterations !== Infinity
      );
    await Promise.allSettled(running.map((animation) => animation.finished));
  });
}
